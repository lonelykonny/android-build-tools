#!/usr/bin/env python3
# =============================================================================
# buildserver.py
# Petit serveur HTTP local (stdlib uniquement, aucune dependance) qui pilote
# la toolchain android-build-tools depuis une app Android.
#
# Tourne DANS le proot Ubuntu (ou Termux si la chaine y est). Ecoute sur
# 127.0.0.1:8765 par defaut. L'app Android tape sur ce port via localhost.
#
# Endpoints :
#   GET  /status            -> etat de la chaine (chain ready ? sdk ? versions)
#   POST /build {url,branch,...} -> demarre un build, renvoie {job_id}
#   GET  /logs/<job_id>?from=N -> lignes de log a partir de l'index N (poll)
#   GET  /jobs               -> historique des builds
#   GET  /job/<job_id>       -> etat d'un job (running/success/failed + apk)
#   GET  /apk/<job_id>       -> telecharge l'APK produit
#   POST /setup               -> (re)lance le setup de la chaine : setup-termux-native.sh
#                                 si present (natif, cas normal), sinon setup-aapt2-qemu.sh
#                                 (ancienne chaine proot+qemu) en repli.
#
# Securite : bind sur 127.0.0.1 uniquement (pas exposé au reseau). Un token
# simple peut etre exige via l'entete X-Build-Token (voir TOKEN ci-dessous).
# =============================================================================

import json, os, subprocess, threading, time, uuid, shlex, html
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HOME = os.path.expanduser("~")
TOOLS = os.path.join(HOME, "android-build-tools")
BUILDER = os.path.join(TOOLS, "android-builder.sh")            # chaine proot (qemu)
NATIVE_BUILDER = os.path.join(TOOLS, "build-termux-native.sh")  # chaine native (sans qemu)
SETUP = os.path.join(TOOLS, "setup-aapt2-qemu.sh")
NATIVE_SETUP = os.path.join(TOOLS, "setup-termux-native.sh")
SHIM = os.path.join(HOME, "aapt2-shim")
GRADLE_PROPS = os.path.join(HOME, ".gradle", "gradle.properties")

def native_aapt2_path():
    """Chemin de l'aapt2 ARM natif actuellement configure.

    Lit android.aapt2FromMavenOverride dans gradle.properties : c'est la
    SEULE source de verite (c'est ce que Gradle utilise reellement), ecrite
    par setup-termux-native.sh. Avant, ce chemin etait re-code en dur ici
    avec le numero de version "35.0.0" duplique depuis setup-termux-native.sh
    -- les deux fichiers devaient rester d'accord manuellement, et rien ne
    signalait un oubli si l'un changeait sans l'autre.
    Repli : si la ligne est absente (setup jamais lance, ou fichier different),
    on cherche le premier aapt2 executable sous android-sdk/build-tools/*/.
    """
    try:
        with open(GRADLE_PROPS, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith("android.aapt2FromMavenOverride="):
                    path = line.split("=", 1)[1].strip()
                    if path:
                        return path
    except OSError:
        pass
    bt_root = os.path.join(HOME, "android-sdk", "build-tools")
    try:
        for entry in sorted(os.listdir(bt_root), reverse=True):
            candidate = os.path.join(bt_root, entry, "aapt2")
            if os.access(candidate, os.X_OK):
                return candidate
    except OSError:
        pass
    # Dernier repli, pour que le reste du code ait toujours une valeur.
    return os.path.join(HOME, "android-sdk", "build-tools", "35.0.0", "aapt2")

DEBIAN_ROOTFS = os.path.join(
    os.environ.get("PREFIX", "/data/data/com.termux/files/usr"),
    "var", "lib", "proot-distro", "containers", "debian")

PORT = int(os.environ.get("BUILD_SERVER_PORT", "8765"))

# Duree max d'un build avant qu'on le tue de force (secondes). Sans ca, un
# gradlew bloque (daemon zombie, reseau capricieux) tournait indefiniment
# sans que l'app APKforge n'ait d'autre moyen de le savoir que de constater
# que les logs n'avancent plus. 45 min par defaut ; surchargeable via env.
BUILD_TIMEOUT_SEC = int(os.environ.get("BUILD_TIMEOUT_SEC", "2700"))

# token optionnel : si defini (env BUILD_SERVER_TOKEN), l'app doit l'envoyer.
TOKEN = os.environ.get("BUILD_SERVER_TOKEN", "")

# --- localisation des messages serveur (EN par defaut, FR si demande) --------
# La langue provient de l'en-tete X-Forge-Lang envoye par l'app APKforge, sinon
# de la variable d'env ABT_LANG, sinon anglais.
def _norm_lang(value):
    v = (value or "").strip().lower()
    return "fr" if v.startswith("fr") else "en"

SERVER_MSG = {
    "launch_error": {"en": "[server] launch error: {e}", "fr": "[serveur] erreur lancement: {e}"},
    "finished": {"en": "[server] finished: {status}", "fr": "[serveur] termine: {status}"},
}

def srv(key, lang, **kw):
    table = SERVER_MSG.get(key, {})
    txt = table.get(_norm_lang(lang), table.get("en", key))
    return txt.format(**kw)

def _script_env(lang, mem=0):
    """Environnement passe aux scripts shell, avec ABT_LANG propage.
    Si mem (Mo) > 0, on fixe GRADLE_JVMARGS pour que build-termux-native.sh /
    setup ecrive cette limite de heap (ecrase le -Xmx du projet)."""
    env = dict(os.environ)
    env["ABT_LANG"] = _norm_lang(lang or os.environ.get("ABT_LANG", "en"))
    if mem and int(mem) > 0:
        env["GRADLE_JVMARGS"] = (
            f"-Xmx{int(mem)}m -XX:MaxMetaspaceSize=512m -Dfile.encoding=UTF-8"
        )
    return env

# --- detection : un echec native justifie-t-il un fallback proot ? -----------
# On ne bascule QUE sur des erreurs liees a la CHAINE (aapt2/SDK/plateforme),
# pas sur des erreurs du PROJET (Kotlin/Java cassent, deps introuvables) :
# refaire en proot ne corrigerait pas un bug de code, ce serait du temps perdu.
#
# IMPORTANT : ces signatures doivent etre suffisamment specifiques pour ne PAS
# matcher la sortie normale d'un build reussi-puis-echoue-ailleurs. L'ancienne
# signature generique "aapt2" matchait par coincidence la ligne
# "WARNING: ... android.aapt2FromMavenOverride=.../aapt2" qui apparait dans
# TOUS les logs de la chaine native (succes ou echec), ce qui pouvait
# declencher un fallback proot pour des raisons sans rapport avec aapt2.
# On utilise desormais des messages d'erreur complets, pas des substrings de
# chemin de fichier.
CHAIN_ERROR_SIGNATURES = (
    "failed to load include path",       # aapt2 ne lit pas android.jar
    "loadedarsc.cpp",                    # parsing arsc casse (aapt2)
    "res_table_type_type",               # crash aapt2 sur la table de ressources
    "custom aapt2 location does not point",  # override aapt2 casse
    "requires compilesdk",               # compileSdk trop recent pour le natif
    "requires compile sdk",
    "syntax error: word unexpected",     # binaire build-tools x86 (aidl/zipalign/aapt)
    "exec format error",                 # binaire mauvaise architecture
)

# Signatures d'erreur PROJET : si presentes, NE PAS basculer (echec legitime).
PROJECT_ERROR_SIGNATURES = (
    "unresolved reference",
    "could not resolve",
    "could not find",
    "compilation error",
    "kotlin compilation",
    "cannot find symbol",
)

def fallback_warranted(lines):
    """True si l'echec native vient de la chaine (et pas du projet)."""
    blob = "\n".join(lines).lower()
    # Un signe clair d'erreur projet annule le fallback.
    if any(sig in blob for sig in PROJECT_ERROR_SIGNATURES):
        return False
    # Sinon, on bascule si une signature de chaine est presente.
    return any(sig in blob for sig in CHAIN_ERROR_SIGNATURES)

# --- installation a la volee du fallback Debian ------------------------------
# Constantes pour le bootstrap (lance cote TERMUX, hors du proot).
PREFIX_DIR = os.environ.get("PREFIX", "/data/data/com.termux/files/usr")
BOOTSTRAP = os.path.join(TOOLS, "bootstrap-debian-build.sh")
PROOT_DISTRO = os.path.join(PREFIX_DIR, "bin", "proot-distro")

def debian_installable():
    """True si on peut tenter d'installer Debian (script + proot-distro presents)."""
    return os.path.exists(BOOTSTRAP) and os.path.exists(PROOT_DISTRO)

def install_debian_fallback(log):
    """Installe le proot Debian minimal a la volee. Renvoie True si succes.
    N'est appele QUE lorsqu'un echec native est juge lie a la chaine."""
    if not debian_installable():
        log("[server] fallback Debian indisponible "
            "(bootstrap-debian-build.sh ou proot-distro absent).")
        return False
    log("[server] installation du fallback Debian (une fois)...")
    rc = 1
    try:
        proc = subprocess.Popen(
            ["bash", BOOTSTRAP],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in proc.stdout:
            log(line.rstrip("\n"))
        rc = proc.wait()
    except Exception as e:
        log(f"[server] erreur installation Debian : {e}")
        return False
    if rc == 0 and os.path.isdir(DEBIAN_ROOTFS):
        log("[server] fallback Debian installe.")
        return True
    log(f"[server] echec installation Debian (rc={rc}).")
    return False

# --- etat en memoire des jobs ------------------------------------------------
# JOBS n'est jamais vide de lui-meme : chaque build garde toutes ses lignes de
# log indefiniment. Sur un serveur qui tourne plusieurs jours avec beaucoup de
# builds, ca peut consommer pas mal de RAM sur un telephone. On borne donc :
# - le nombre de jobs TERMINES conserves dans l'historique (MAX_JOBS_HISTORY)
# - le nombre de lignes de log gardees par job termine (MAX_LOG_LINES_KEPT),
#   en gardant le debut (contexte) et la fin (l'erreur), pas le milieu.
JOBS = {}  # job_id -> dict(status, url, lines[], apk, started, ended)
JOBS_LOCK = threading.Lock()
MAX_JOBS_HISTORY = int(os.environ.get("MAX_JOBS_HISTORY", "30"))
MAX_LOG_LINES_KEPT = int(os.environ.get("MAX_LOG_LINES_KEPT", "2000"))

def _prune_jobs():
    """A appeler quand un job se termine. Purge les jobs finis les plus
    anciens au-dela de MAX_JOBS_HISTORY, et tronque les logs des jobs finis
    trop longs. Le job en cours (s'il y en a un autre) n'est jamais touche."""
    with JOBS_LOCK:
        finished = sorted(
            (j for j in JOBS.values() if j["status"] != "running"),
            key=lambda j: j.get("ended") or 0,
        )
        excess = len(finished) - MAX_JOBS_HISTORY
        for j in finished[:max(excess, 0)]:
            JOBS.pop(j["id"], None)

        for j in JOBS.values():
            if j["status"] == "running":
                continue
            n = len(j["lines"])
            if n > MAX_LOG_LINES_KEPT:
                head = j["lines"][:200]
                tail = j["lines"][-(MAX_LOG_LINES_KEPT - 200):]
                omitted = n - len(head) - len(tail)
                j["lines"] = head + [f"... ({omitted} lignes omises pour limiter la memoire) ..."] + tail

def new_job(url, branch, subdir, task, mem=0):
    jid = uuid.uuid4().hex[:12]
    with JOBS_LOCK:
        JOBS[jid] = {
            "id": jid, "url": url, "branch": branch, "subdir": subdir,
            "task": task, "status": "running", "lines": [], "apk": None,
            "started": time.time(), "ended": None,
            # Heap Gradle en Mo demande par l'app (0 = laisser le defaut du
            # gradle.properties global pose par setup-termux-native.sh).
            "mem": int(mem) if mem else 0,
        }
    return jid

def _run_chain(job, cmd, log, timeout_sec=None):
    """Lance une commande de build, streame le log, renvoie (rc, lines_de_ce_run).

    Si timeout_sec est fourni, un watchdog termine le process s'il tourne
    encore apres ce delai (daemon Gradle bloque, reseau qui ne repond plus...)
    au lieu de laisser le job "running" indefiniment."""
    start_idx = len(job["lines"])
    log(f"$ {' '.join(shlex.quote(c) for c in cmd)}")
    timed_out = threading.Event()
    watchdog = None
    try:
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1, env=_script_env(job.get("lang"), job.get("mem", 0)),
        )

        if timeout_sec:
            def _kill_on_timeout():
                timed_out.set()
                log(f"[server] timeout ({timeout_sec}s) depasse, arret du build.")
                try:
                    proc.terminate()
                    time.sleep(2)
                    if proc.poll() is None:
                        proc.kill()
                except Exception:
                    pass
            watchdog = threading.Timer(timeout_sec, _kill_on_timeout)
            watchdog.daemon = True
            watchdog.start()

        for line in proc.stdout:
            log(line)
        proc.wait()
        rc = proc.returncode
        if watchdog:
            watchdog.cancel()
        if timed_out.is_set() and rc == 0:
            rc = 1  # tue de force : ne jamais rapporter un succes
    except Exception as e:
        if watchdog:
            watchdog.cancel()
        log(srv("launch_error", job.get("lang"), e=e))
        rc = 1
    with JOBS_LOCK:
        run_lines = list(job["lines"][start_idx:])
    return rc, run_lines

def _find_apk(url):
    repo_dir = os.path.join(HOME, "android-builds", os.path.basename(
        url.rstrip("/")).replace(".git", ""))
    for root, _dirs, files in os.walk(repo_dir):
        if "outputs" in root:
            for f in files:
                if f.endswith(".apk"):
                    return os.path.join(root, f)
    return None

def run_build(jid):
    job = JOBS[jid]

    def log(line):
        with JOBS_LOCK:
            job["lines"].append(line.rstrip("\n"))

    # Options communes a passer aux deux scripts.
    opts = []
    if job["branch"]:
        opts += ["--branch", job["branch"]]
    if job["subdir"]:
        opts += ["--subdir", job["subdir"]]
    if job["task"]:
        opts += ["--task", job["task"]]

    aapt2 = native_aapt2_path()
    native_ok = os.path.exists(NATIVE_BUILDER) and os.access(aapt2, os.X_OK)
    proot_ok = os.path.exists(BUILDER) and os.path.isdir(DEBIAN_ROOTFS)

    rc = 1
    chain_used = None
    do_proot = False  # decide-t-on de (re)tenter en proot ?

    # --- 1) Tentative NATIVE (rapide, sans qemu) -----------------------------
    if native_ok:
        log("[server] chaine NATIVE (sans qemu)")
        cmd = ["bash", NATIVE_BUILDER, job["url"]] + opts
        rc, run_lines = _run_chain(job, cmd, log, timeout_sec=BUILD_TIMEOUT_SEC)
        chain_used = "native"
        if rc == 0:
            do_proot = False
        elif not fallback_warranted(run_lines):
            log("[server] echec du projet (pas la chaine) -> pas de bascule")
        elif proot_ok:
            log("[server] echec lie a la chaine -> bascule sur le proot (qemu)")
            do_proot = True
        else:
            # Echec lie a la chaine mais pas de proot : on l'installe a la volee,
            # uniquement maintenant qu'on sait qu'il pourrait aider.
            log("[server] echec lie a la chaine ; pas de proot -> installation a la volee")
            if install_debian_fallback(log):
                proot_ok = os.path.exists(BUILDER) and os.path.isdir(DEBIAN_ROOTFS)
                do_proot = proot_ok
            else:
                log("[server] fallback Debian indisponible -> abandon")
    elif proot_ok:
        # Pas de chaine native : on va directement en proot.
        log("[server] chaine native absente -> proot directement")
        do_proot = True
    else:
        log("[server] aucune chaine disponible (ni native ni proot).")

    # --- 2) Build PROOT (robuste, fallback ou voie directe) ------------------
    if do_proot:
        log("[server] chaine PROOT (Debian + qemu)")
        cmd = ["bash", BUILDER, job["url"]] + opts
        rc, _ = _run_chain(job, cmd, log, timeout_sec=BUILD_TIMEOUT_SEC)
        chain_used = "proot"

    # --- 3) APK + statut -----------------------------------------------------
    apk = _find_apk(job["url"])
    with JOBS_LOCK:
        job["status"] = "success" if rc == 0 else "failed"
        job["apk"] = apk
        job["chain"] = chain_used
        job["ended"] = time.time()
        log(srv("finished", job.get("lang"), status=job["status"])
            + (f" [{chain_used}]" if chain_used else "")
            + (f" apk={apk}" if apk else ""))
    _prune_jobs()

def chain_status():
    sdk = os.path.join(HOME, "android-sdk")
    aapt2 = native_aapt2_path()
    native_ready = os.path.exists(aapt2) and os.access(aapt2, os.X_OK)
    proot_ready = os.path.isdir(DEBIAN_ROOTFS) and os.path.exists(BUILDER)
    return {
        # 'chain_ready' reste vrai si AU MOINS une chaine est utilisable.
        "chain_ready": native_ready or proot_ready,
        "native_ready": native_ready,  # chaine Termux native (aapt2 ARM, sans qemu)
        "proot_ready": proot_ready,    # chaine proot Debian (qemu) en secours
        "builder_present": os.path.exists(BUILDER) or os.path.exists(NATIVE_BUILDER),
        "sdk_present": os.path.isdir(sdk),
        "aapt2_native": aapt2 if native_ready else None,
    }

class Handler(BaseHTTPRequestHandler):
    server_version = "AndroidBuildServer/1.0"

    # --- helpers -------------------------------------------------------------
    def _auth_ok(self):
        if not TOKEN:
            return True
        return self.headers.get("X-Build-Token", "") == TOKEN

    def _from_browser(self):
        """True si la requete porte des en-tetes que seul un navigateur ajoute
        (Origin / Referer / Sec-Fetch-*). Le client de l'app (OkHttp) n'en
        envoie jamais.

        Le serveur n'est destine qu'a l'app APKforge (client HTTP natif) tournant
        sur le meme telephone. Il n'a AUCUNE raison d'accepter des requetes
        provenant d'une page web : une page ouverte dans un navigateur sur le
        telephone (voire dans une autre appli) pourrait sinon appeler
        127.0.0.1:8765/build a l'insu de l'utilisateur et lancer un build
        arbitraire. On rejette donc toute requete qui ressemble a une requete
        de navigateur, plutot que de s'appuyer uniquement sur CORS (les
        soumissions de formulaire "simple request" contournent le CORS)."""
        h = self.headers
        return any(h.get(k) for k in ("Origin", "Referer", "Sec-Fetch-Site"))

    def _ui_lang(self):
        # Langue de l'UI APKforge, envoyee par l'app via X-Forge-Lang (ex: "fr").
        return _norm_lang(self.headers.get("X-Forge-Lang", ""))

    def _send(self, code, obj, ctype="application/json"):
        # Pas de Access-Control-Allow-Origin: aucun usage legitime de ce serveur
        # ne se fait depuis du JS de navigateur (voir _from_browser). Emettre un
        # CORS permissif ne ferait qu'ouvrir la porte a des requetes cross-site.
        body = obj if isinstance(obj, (bytes, bytearray)) else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        if n == 0:
            return {}
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return {}

    def log_message(self, *a):
        pass  # silence

    # --- routes --------------------------------------------------------------
    def do_GET(self):
        if self._from_browser():
            return self._send(403, {"error": "browser requests are not allowed"})
        if not self._auth_ok():
            return self._send(401, {"error": "unauthorized"})
        u = urlparse(self.path)
        parts = [p for p in u.path.split("/") if p]
        q = parse_qs(u.query)

        if u.path == "/status":
            return self._send(200, chain_status())

        if u.path == "/jobs":
            with JOBS_LOCK:
                out = [{k: j[k] for k in ("id", "url", "status", "started", "ended")}
                       for j in JOBS.values()]
            return self._send(200, {"jobs": out})

        if len(parts) == 2 and parts[0] == "job":
            j = JOBS.get(parts[1])
            if not j:
                return self._send(404, {"error": "no such job"})
            with JOBS_LOCK:
                view = {k: j[k] for k in ("id", "url", "status", "apk", "started", "ended")}
                view["n_lines"] = len(j["lines"])
            return self._send(200, view)

        if len(parts) == 2 and parts[0] == "logs":
            j = JOBS.get(parts[1])
            if not j:
                return self._send(404, {"error": "no such job"})
            frm = int((q.get("from", ["0"])[0]) or 0)
            with JOBS_LOCK:
                lines = j["lines"][frm:]
                total = len(j["lines"])
                status = j["status"]
            return self._send(200, {"from": frm, "next": total,
                                     "status": status, "lines": lines})

        if len(parts) == 2 and parts[0] == "apk":
            j = JOBS.get(parts[1])
            if not j or not j.get("apk") or not os.path.exists(j["apk"]):
                return self._send(404, {"error": "apk not available"})
            with open(j["apk"], "rb") as f:
                data = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "application/vnd.android.package-archive")
            self.send_header("Content-Disposition",
                              f'attachment; filename="{os.path.basename(j["apk"])}"')
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        return self._send(404, {"error": "not found"})

    def do_POST(self):
        if self._from_browser():
            return self._send(403, {"error": "browser requests are not allowed"})
        if not self._auth_ok():
            return self._send(401, {"error": "unauthorized"})
        u = urlparse(self.path)

        if u.path == "/build":
            body = self._read_json()
            url = (body.get("url") or "").strip()
            branch = (body.get("branch") or "").strip()
            subdir = (body.get("subdir") or "").strip()
            task = (body.get("task") or "assembleDebug").strip()
            if not url:
                return self._send(400, {"error": "url required"})
            # Garde-fou : une valeur commencant par '-' pourrait etre interpretee
            # comme une option par git ou gradlew en aval (ex: "--upload-pack=..."
            # ou "--init-script=...") plutot que comme une URL/branche/sous-dossier/
            # tache. Aucune valeur legitime ne commence par un tiret.
            for name, val in (("url", url), ("branch", branch),
                              ("subdir", subdir), ("task", task)):
                if val.startswith("-"):
                    return self._send(400, {"error": f"invalid {name}"})
            jid = new_job(url, branch, subdir, task, body.get("mem", 0))
            JOBS[jid]["lang"] = self._ui_lang()
            threading.Thread(target=run_build, args=(jid,), daemon=True).start()
            return self._send(200, {"job_id": jid})

        if u.path == "/setup":
            jid = uuid.uuid4().hex[:12]
            with JOBS_LOCK:
                JOBS[jid] = {"id": jid, "url": "(setup)", "status": "running",
                             "lines": [], "apk": None, "started": time.time(),
                             "ended": None, "branch": "", "subdir": "", "task": "",
                             "lang": self._ui_lang()}

            def run_setup():
                job = JOBS[jid]
                try:
                    setup_script = NATIVE_SETUP if os.path.exists(NATIVE_SETUP) else SETUP
                    proc = subprocess.Popen(["bash", setup_script], stdout=subprocess.PIPE,
                                             stderr=subprocess.STDOUT, text=True, bufsize=1,
                                             env=_script_env(job.get("lang")))
                    for line in proc.stdout:
                        with JOBS_LOCK:
                            job["lines"].append(line.rstrip("\n"))
                    proc.wait()
                    rc = proc.returncode
                except Exception as e:
                    with JOBS_LOCK:
                        job["lines"].append(srv("launch_error", job.get("lang"), e=e))
                    rc = 1
                with JOBS_LOCK:
                    job["status"] = "success" if rc == 0 else "failed"
                    job["ended"] = time.time()
                _prune_jobs()

            threading.Thread(target=run_setup, daemon=True).start()
            return self._send(200, {"job_id": jid})

        return self._send(404, {"error": "not found"})

    def do_OPTIONS(self):
        # Pas de Access-Control-Allow-Origin : voir _from_browser / _send.
        # Ce serveur n'est destine qu'au client HTTP natif de l'app APKforge.
        self.send_response(204)
        self.end_headers()

def main():
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"[build-server] ecoute sur http://127.0.0.1:{PORT}")
    print(f"[build-server] chaine: {chain_status()}")
    if TOKEN:
        print("[build-server] token requis (X-Build-Token)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n[build-server] arret.")

if __name__ == "__main__":
    main()
