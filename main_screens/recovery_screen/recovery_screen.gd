class_name RecoveryScreen
extends Control

## Ecran de recovery : point d'entree de l'application udg-recovery. Repris
## de l'ecran de reglages du jeu (udg-test, settings_screen). Trois mises a
## jour (voir udg-yocto : meta-udg-min pour le pipeline RAUC app-only A/B +
## recovery, et doc/DARTBOARD-INTERFACE.md pour la carte d'interface cible) :
##
## 1. "Check for update from USB" (application) : liste tous les fichiers
## .raucb trouves dans UPDATE_DIR (convention retenue : la cle USB est
## montee - ou son contenu copie - a ce chemin fixe, /media/udg-update) et
## laisse choisir lequel installer - plusieurs versions peuvent cohabiter sur
## la meme cle (ex. pour revenir en arriere). Sur selection, lit sa version
## via `rauc info`, puis demande confirmation ("Application vX.Y.Z, Do you
## want to upgrade?"). Sur confirmation, `udg-app-selector.sh --install`
## tourne dans un thread (ca peut prendre du temps) ; une fois termine avec
## succes, le meme dialogue est reutilise pour proposer un redemarrage
## (udg-app-selector.sh reprend la main au prochain demarrage et bascule sur
## le nouveau slot) - voir _confirm_action, qui distingue les deux usages du
## dialogue.
##
## PAS `rauc install` directement : bootloader=noop empeche RAUC de
## determiner seul le slot inactif, donc il installerait toujours dans le
## meme slot. udg-app-selector.sh --install verifie la signature puis ecrit
## dans le slot que l'etat systeme sait etre inactif.
##
## 1bis. "Check for update online" (application) : meme installation que
## ci-dessus, mais le bundle vient de la derniere release GitHub du depot
## udg-app (GITHUB_LATEST_RELEASE_URL). A la difference du Settings du jeu,
## AUCUNE comparaison avec la version actuellement installee n'est faite ici
## : contrairement au jeu, la recovery ne sait pas forcement quelle version
## de l'application tourne sur l'autre slot (et elle sert justement aussi
## quand l'application est cassee ou absente) - elle affiche simplement la
## derniere version disponible et laisse l'utilisateur decider, comme pour
## le flux USB. Si la release porte un fichier .raucb, on demande
## confirmation, on telecharge le bundle dans DOWNLOAD_DIR (avec
## progression), puis on lance la meme installation que pour l'USB
## (udg-app-selector.sh verifie la signature RAUC : un bundle non signe par
## notre cle est refuse, quelle que soit sa provenance). Le fichier
## telecharge est supprime a la fin de l'installation. Sans reseau, affiche
## simplement que GitHub est injoignable.
##
## 2. "DartBoard Interface Update" (firmware du Raspberry Pi Pico) : meme
## principe avec les fichiers udg_dartboard_if_MM.mm.bbbb.dpkg. Chaque
## candidat est valide par `udg-dartboard-flash --info` (les fichiers
## invalides sont ignores), puis la version actuelle (commande `alive` sur
## /dev/udg-dartboard) et la version cible sont affichees pour confirmation.
## Le flash (`udg-dartboard-flash <fichier>`, bloquant) est lance en
## processus separe surveille par un timeout global ; ensuite on attend que
## le port reapparaisse et on verifie par `alive` que la nouvelle version
## est bien celle du fichier. Le jeu n'ouvre jamais le port serie lui-meme
## (il est ouvert brievement, en `stty raw -echo`, par _read_alive_version) :
## rien a fermer avant le flash. Aucune politique sur les retrogradations
## (l'outil ne les interdit pas) : le choix est laisse a l'utilisateur.
##
## Le bouton "Reboot" permet de quitter la recovery sans mise a jour.
##
## Suppose que quelque chose (udev/systemd, hors scope de ce script) monte
## deja la cle USB sur ce chemin fixe : ce script ne monte rien lui-meme.
## Suppose aussi que le processus a le droit d'executer ces outils (la
## recovery tourne en root sur l'image actuelle). Sans ces binaires ni ce
## point de montage (ex. en test dans l'editeur sous Windows), se degrade
## proprement sur "No update found".
##
## Pas de fonctionnalite "DartBoard Interface Test" ici (contrairement au
## Settings du jeu) : ce diagnostic materiel se connecte via
## DartInputManager, un autoload propre au jeu (dart_input/) que la
## recovery n'embarque pas - hors de son perimetre.

## Chemin fixe ou la cle USB de mise a jour est attendue montee (convention
## retenue avec l'equipe systeme, voir doc de classe ci-dessus).
const UPDATE_DIR := "/media/udg-update"
const BUNDLE_EXTENSION := ".raucb"

const GITHUB_LATEST_RELEASE_URL := "https://api.github.com/repos/christopheseyler/udg-app/releases/latest"
## Dossier (persistant, hors tmpfs) ou est telecharge le bundle avant installation.
const DOWNLOAD_DIR := "user://update"
const RELEASE_CHECK_TIMEOUT_S := 15.0
const BUNDLE_DOWNLOAD_TIMEOUT_S := 900.0

const DARTBOARD_FILE_PREFIX := "udg_dartboard_if_"
const DARTBOARD_FILE_EXTENSION := ".dpkg"
const DARTBOARD_FLASH_TOOL := "/usr/bin/udg-dartboard-flash"
const DARTBOARD_PORT := "/dev/udg-dartboard"
## Timeout global du flash (l'outil est bloquant et n'a pas de timeout propre).
const DARTBOARD_FLASH_TIMEOUT_S := 60.0
## Delai max pour que le port serie reapparaisse apres le flash.
const DARTBOARD_PORT_WAIT_S := 10.0
const DARTBOARD_FLASH_LOG := "/tmp/udg-dartboard-flash.log"
const DARTBOARD_FLASH_RC := "/tmp/udg-dartboard-flash.rc"
const DARTBOARD_ALIVE_LOG := "/tmp/udg-dartboard-alive.out"

## Ce que "Yes" declenche dans le dialogue de confirmation, partage entre
## la confirmation d'upgrade, celle de telechargement et la proposition de
## redemarrage qui suit une installation reussie.
enum ConfirmAction { NONE, UPGRADE, DOWNLOAD, REBOOT }

## Quelle mise a jour est en cours de selection / d'installation.
enum UpdateKind { APP, DARTBOARD }

@onready var check_update_button: Button = $Panel/Layout/Margin/Content/Buttons/CheckUpdateButton
@onready var check_online_button: Button = $Panel/Layout/Margin/Content/Buttons/CheckOnlineUpdateButton
@onready var dartboard_update_button: Button = $Panel/Layout/Margin/Content/Buttons/DartboardUpdateButton
@onready var reboot_button: Button = $Panel/Layout/Margin/Content/Buttons/RebootButton
@onready var status_label: Label = $Panel/Layout/Margin/Content/Selection/StatusLabel
@onready var bundle_scroll: ScrollContainer = $Panel/Layout/Margin/Content/Selection/BundleScroll
@onready var bundle_list: VBoxContainer = $Panel/Layout/Margin/Content/Selection/BundleScroll/BundleList
@onready var confirm_overlay: Control = $ConfirmOverlay
@onready var confirm_label: Label = $ConfirmOverlay/Center/Dialog/Margin/Content/ConfirmLabel
@onready var no_button: Button = $ConfirmOverlay/Center/Dialog/Margin/Content/Buttons/NoButton
@onready var yes_button: Button = $ConfirmOverlay/Center/Dialog/Margin/Content/Buttons/YesButton

var _pending_bundle_path := ""
var _pending_kind := UpdateKind.APP
var _pending_target_version := ""
## Vrai si _pending_bundle_path est un fichier telecharge (a supprimer apres
## l'installation) plutot qu'un fichier de la cle USB.
var _pending_is_download := false
var _online_version := ""
var _online_asset_url := ""
var _online_asset_name := ""
var _download_request: HTTPRequest
var _install_thread: Thread
var _confirm_action := ConfirmAction.NONE

func _ready() -> void:
	check_update_button.pressed.connect(_on_check_update_pressed)
	check_online_button.pressed.connect(_on_check_online_pressed)
	dartboard_update_button.pressed.connect(_on_dartboard_update_pressed)
	reboot_button.pressed.connect(_on_reboot_pressed)
	no_button.pressed.connect(_on_confirm_no)
	yes_button.pressed.connect(_on_confirm_yes)
	bundle_scroll.visible = false
	set_process(false)

func _on_reboot_pressed() -> void:
	_confirm_action = ConfirmAction.REBOOT
	confirm_label.text = "Restart now?"
	confirm_overlay.visible = true

func _exit_tree() -> void:
	if _install_thread:
		_install_thread.wait_to_finish()

func _on_check_update_pressed() -> void:
	_set_status("Looking for a USB drive...")
	_clear_bundle_list()

	var bundle_paths := _find_files(BUNDLE_EXTENSION, "")
	if bundle_paths.is_empty():
		_set_status("No update found on USB.")
		return

	_set_status("Found %d update(s) on USB. Choose one:" % bundle_paths.size())
	for path in bundle_paths:
		_add_list_button(path.get_file(), _on_bundle_selected.bind(path))
	bundle_scroll.visible = true

func _on_check_online_pressed() -> void:
	_set_status("Checking for updates online...")
	_clear_bundle_list()
	_set_busy(true)

	var request := _new_http_request(RELEASE_CHECK_TIMEOUT_S)
	request.request_completed.connect(_on_release_info_received.bind(request))
	var headers := PackedStringArray(["Accept: application/vnd.github+json", "User-Agent: udg-recovery"])
	if request.request(GITHUB_LATEST_RELEASE_URL, headers) != OK:
		request.queue_free()
		_set_busy(false)
		_set_status("Could not start the online check.")

func _new_http_request(timeout_s: float) -> HTTPRequest:
	var request := HTTPRequest.new()
	request.timeout = timeout_s
	add_child(request)
	return request

func _on_release_info_received(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, request: HTTPRequest) -> void:
	request.queue_free()
	_set_busy(false)

	if result != HTTPRequest.RESULT_SUCCESS:
		_set_status("Could not reach GitHub (no connection?). HTTPRequest result: %d" % result)
		return
	if code == 404:
		_set_status("No release published yet.")
		return
	if code != 200:
		_set_status("GitHub answered HTTP %d." % code)
		return

	var data = JSON.parse_string(body.get_string_from_utf8())
	if not data is Dictionary:
		_set_status("Unexpected answer from GitHub.")
		return

	var remote_version := str(data.get("tag_name", "")).trim_prefix("v")
	if remote_version == "":
		_set_status("Unexpected answer from GitHub.")
		return

	var asset := _find_bundle_asset(data.get("assets", []))
	if asset.is_empty():
		_set_status("Release v%s has no update bundle." % remote_version)
		return

	_online_version = remote_version
	_online_asset_url = asset.url
	_online_asset_name = asset.name
	_confirm_action = ConfirmAction.DOWNLOAD
	confirm_label.text = "Application v%s available online\nDownload and upgrade?" % remote_version
	confirm_overlay.visible = true
	_set_status("Update v%s available." % remote_version)

## Premier asset .raucb d'une release, sous forme {name, url}, ou {} s'il n'y en a pas.
func _find_bundle_asset(assets) -> Dictionary:
	if not assets is Array:
		return {}
	for asset in assets:
		if asset is Dictionary:
			var asset_name := str(asset.get("name", ""))
			var url := str(asset.get("browser_download_url", ""))
			if asset_name.ends_with(BUNDLE_EXTENSION) and url != "":
				return {"name": asset_name, "url": url}
	return {}

func _start_download() -> void:
	var dir := ProjectSettings.globalize_path(DOWNLOAD_DIR)
	if DirAccess.make_dir_recursive_absolute(dir) != OK:
		_set_status("Could not create the download folder.")
		return
	var path := dir.path_join(_online_asset_name.get_file())

	_set_busy(true)
	_set_status("Downloading v%s..." % _online_version)
	_download_request = _new_http_request(BUNDLE_DOWNLOAD_TIMEOUT_S)
	_download_request.download_file = path
	_download_request.request_completed.connect(_on_download_finished.bind(_download_request, path))
	if _download_request.request(_online_asset_url) != OK:
		_download_request.queue_free()
		_download_request = null
		_set_busy(false)
		_set_status("Could not start the download.")
		return
	set_process(true)

func _process(_delta: float) -> void:
	if _download_request == null:
		set_process(false)
		return
	var done := _download_request.get_downloaded_bytes()
	var total := _download_request.get_body_size()
	var done_mb := done / 1048576.0
	if total > 0:
		_set_status("Downloading v%s... %d%% (%.1f / %.1f MB)" % [_online_version, 100 * done / total, done_mb, total / 1048576.0])
	else:
		_set_status("Downloading v%s... %.1f MB" % [_online_version, done_mb])

func _on_download_finished(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray, request: HTTPRequest, path: String) -> void:
	request.queue_free()
	_download_request = null
	set_process(false)

	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		DirAccess.remove_absolute(path)
		_set_busy(false)
		_set_status("Download failed (result %d, HTTP %d)." % [result, code])
		return

	_pending_bundle_path = path
	_pending_kind = UpdateKind.APP
	_pending_is_download = true
	_start_install()

func _on_dartboard_update_pressed() -> void:
	_set_status("Looking for a USB drive...")
	_clear_bundle_list()

	var found: Array[Dictionary] = []
	for path in _find_files(DARTBOARD_FILE_EXTENSION, DARTBOARD_FILE_PREFIX):
		var info := _read_dartboard_file_info(path)
		if info.ok:
			found.append({"path": path, "version": info.version})
	if found.is_empty():
		_set_status("No valid DartBoard Interface update found on USB.")
		return

	_set_status("Found %d DartBoard Interface update(s) on USB. Choose one:" % found.size())
	for item in found:
		_add_list_button(
			"%s (v%s)" % [item.path.get_file(), item.version],
			_on_dartboard_file_selected.bind(item.path, item.version))
	bundle_scroll.visible = true

func _add_list_button(text: String, on_pressed: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, 90)
	button.add_theme_font_size_override("font_size", 32)
	button.pressed.connect(on_pressed)
	bundle_list.add_child(button)

func _clear_bundle_list() -> void:
	bundle_scroll.visible = false
	for child in bundle_list.get_children():
		bundle_list.remove_child(child)
		child.queue_free()

## Liste les fichiers directement sous UPDATE_DIR ayant l'extension (et le
## prefixe, s'il n'est pas vide) donnes, tries par nom. Renvoie un tableau
## vide si le dossier n'existe pas (pas de cle montee) ou ne contient rien
## de correspondant.
func _find_files(extension: String, prefix: String) -> Array[String]:
	var paths: Array[String] = []
	var dir := DirAccess.open(UPDATE_DIR)
	if dir == null:
		return paths

	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.ends_with(extension) and entry.begins_with(prefix):
			paths.append(UPDATE_DIR.path_join(entry))
		entry = dir.get_next()
	dir.list_dir_end()

	paths.sort()
	return paths

func _on_bundle_selected(path: String) -> void:
	var info := _read_bundle_info(path)
	if not info.ok:
		_set_status("Could not read %s: %s" % [path.get_file(), info.error])
		return

	_pending_bundle_path = path
	_pending_kind = UpdateKind.APP
	_pending_is_download = false
	_confirm_action = ConfirmAction.UPGRADE
	confirm_label.text = "Application v%s\nDo you want to upgrade?" % info.version
	confirm_overlay.visible = true

func _on_dartboard_file_selected(path: String, target_version: String) -> void:
	var current_version := _read_alive_version()
	var current_text := ("v" + current_version) if current_version != "" else "unknown"

	_pending_bundle_path = path
	_pending_kind = UpdateKind.DARTBOARD
	_pending_target_version = target_version
	_confirm_action = ConfirmAction.UPGRADE
	confirm_label.text = "DartBoard Interface\n%s -> v%s\nDo you want to upgrade?" % [current_text, target_version]
	confirm_overlay.visible = true

## Lit le manifeste du bundle via `rauc info` (verifie sa structure, pas sa
## signature : `udg-app-selector.sh --install` la verifiera de toute facon).
func _read_bundle_info(path: String) -> Dictionary:
	var output := []
	var exit_code := OS.execute("rauc", ["info", path], output, true)
	var text: String = output[0] if output.size() > 0 else ""
	if exit_code != 0:
		# Derniere ligne de la sortie de rauc (le motif de l'echec y figure).
		var lines := text.strip_edges().split("\n")
		var reason: String = lines[lines.size() - 1].strip_edges() if not lines.is_empty() else ""
		return {"ok": false, "error": "rauc info exited with code %d: %s" % [exit_code, reason]}

	var version := _extract_field(text, "Version")
	if version == "":
		return {"ok": false, "error": "no version field in bundle manifest"}
	return {"ok": true, "version": version, "compatible": _extract_field(text, "Compatible")}

func _extract_field(text: String, field_name: String) -> String:
	var regex := RegEx.new()
	regex.compile("%s:\\s*'([^']*)'" % field_name)
	var result := regex.search(text)
	return result.get_string(1) if result else ""

## Valide un .dpkg via `udg-dartboard-flash --info` (aucun acces au Pico, sans
## effet de bord). Code 0 : valide, la version s'extrait de la sortie ; code 1 :
## invalide, le motif est sur la sortie d'erreur.
func _read_dartboard_file_info(path: String) -> Dictionary:
	var output := []
	var exit_code := OS.execute(DARTBOARD_FLASH_TOOL, ["--info", path], output, true)
	var text: String = output[0] if output.size() > 0 else ""
	if exit_code != 0:
		return {"ok": false, "error": text.strip_edges()}

	var version := _regex_group(text, "version (\\d\\d\\.\\d\\d\\.\\d{4})")
	if version == "":
		return {"ok": false, "error": "no version in udg-dartboard-flash --info output"}
	return {"ok": true, "version": version}

## Interroge le Pico : `alive` -> `#alive-vMM.mm.bbbb#`. Renvoie la version, ou
## "" si le port n'existe pas ou si le Pico ne repond pas (ex. en BOOTSEL). Le
## port doit etre en raw sans echo a chaque ouverture (sinon le pilote tty et
## le firmware se renvoient les caracteres en boucle) ; pas de `timeout` sur
## l'image, d'ou le `cat` en arriere-plan tue apres 1 s.
func _read_alive_version() -> String:
	var script := (
		"stty -F %s raw -echo && "
		+ "(cat %s > %s & P=$!; sleep 0.3; printf 'alive\\r\\n' > %s; sleep 1; kill $P) 2>/dev/null; "
		+ "tr -d '\\r' < %s"
	) % [DARTBOARD_PORT, DARTBOARD_PORT, DARTBOARD_ALIVE_LOG, DARTBOARD_PORT, DARTBOARD_ALIVE_LOG]
	var output := []
	if OS.execute("sh", ["-c", script], output, true) != 0 or output.is_empty():
		return ""
	return _regex_group(output[0], "#alive-v(\\d\\d\\.\\d\\d\\.\\d{4})#")

func _regex_group(text: String, pattern: String) -> String:
	var regex := RegEx.new()
	regex.compile(pattern)
	var result := regex.search(text)
	return result.get_string(1) if result else ""

func _on_confirm_no() -> void:
	confirm_overlay.visible = false
	_confirm_action = ConfirmAction.NONE

func _on_confirm_yes() -> void:
	confirm_overlay.visible = false
	var action := _confirm_action
	_confirm_action = ConfirmAction.NONE
	match action:
		ConfirmAction.UPGRADE:
			if _pending_kind == UpdateKind.DARTBOARD:
				_flash_dartboard()
			else:
				_start_install()
		ConfirmAction.DOWNLOAD:
			_start_download()
		ConfirmAction.REBOOT:
			OS.execute("systemctl", ["reboot"])

func _set_busy(busy: bool) -> void:
	check_update_button.disabled = busy
	check_online_button.disabled = busy
	dartboard_update_button.disabled = busy
	reboot_button.disabled = busy

func _start_install() -> void:
	_set_status("Installing update, please wait...")
	_set_busy(true)

	_install_thread = Thread.new()
	_install_thread.start(_install_worker.bind(_pending_bundle_path))

## Tourne sur un thread a part : l'installation peut prendre plusieurs
## dizaines de secondes (ecriture du slot inactif), ce qui gelerait
## l'interface si lance sur le thread principal.
##
## Passe par udg-app-selector.sh --install, PAS par `rauc install`
## directement : confirme cote systeme (udg-yocto) que `rauc install`
## ne peut pas fonctionner pour ce design app-only A/B
## (bootloader=noop empeche RAUC de determiner lui-meme le slot
## inactif, donc il cible toujours le meme slot quel que soit celui
## reellement actif). Le wrapper fait exactement ce que `rauc install`
## aurait du faire : verifie la signature (`rauc extract`) puis ecrit
## dans le slot que l'etat systeme sait etre inactif (`rauc
## write-slot`) - voir udg-yocto/scripts/UPDATE-BUNDLE.md.
func _install_worker(bundle_path: String) -> void:
	var output := []
	var exit_code := OS.execute("/usr/bin/udg-app-selector.sh", ["--install", bundle_path], output, true)
	var log_text: String = output[0] if output.size() > 0 else ""
	call_deferred("_on_install_finished", exit_code, log_text)

## Le nouveau slot n'est pris en compte qu'au prochain demarrage
## (udg-app-selector.sh choisit le slot actif au boot) : sur succes, le
## dialogue de confirmation est reutilise (voir ConfirmAction) pour
## proposer un redemarrage immediat.
func _on_install_finished(exit_code: int, log_text: String) -> void:
	_install_thread.wait_to_finish()
	_install_thread = null
	_set_busy(false)
	if _pending_is_download:
		# Le bundle telecharge n'est plus utile (installe ou en echec).
		DirAccess.remove_absolute(_pending_bundle_path)
		_pending_is_download = false

	if exit_code == 0:
		_set_status("Update installed. Restart to switch to the new version.")
		_confirm_action = ConfirmAction.REBOOT
		confirm_label.text = "Update installed.\nRestart now?"
		confirm_overlay.visible = true
	else:
		_set_status("Update failed: %s" % log_text)

## Sequence du doc DARTBOARD-INTERFACE.md §3.5 (apres la confirmation) :
## flash (processus separe + timeout), attente du port, verification `alive`.
## `udg-dartboard-flash` est bloquant : lance via `sh -c` en processus non
## bloquant dont on sonde la fin, pour pouvoir le tuer au bout de
## DARTBOARD_FLASH_TIMEOUT_S sans thread. Le code retour est ecrit dans un
## fichier (OS.create_process ne le renvoie pas).
func _flash_dartboard() -> void:
	_set_busy(true)
	_set_status("Flashing DartBoard Interface, do not power off...")

	DirAccess.remove_absolute(DARTBOARD_FLASH_RC)
	var command := "%s '%s' > %s 2>&1; echo $? > %s" % [
		DARTBOARD_FLASH_TOOL, _pending_bundle_path, DARTBOARD_FLASH_LOG, DARTBOARD_FLASH_RC]
	var pid := OS.create_process("sh", ["-c", command])
	if pid <= 0:
		_finish_dartboard_update(false, "could not start udg-dartboard-flash")
		return

	var waited := 0.0
	while OS.is_process_running(pid):
		if waited >= DARTBOARD_FLASH_TIMEOUT_S:
			OS.kill(pid)
			_finish_dartboard_update(false, "flash timed out after %d s" % int(DARTBOARD_FLASH_TIMEOUT_S))
			return
		await get_tree().create_timer(0.5).timeout
		waited += 0.5

	var rc := FileAccess.get_file_as_string(DARTBOARD_FLASH_RC).strip_edges()
	if rc != "0":
		var log_text := FileAccess.get_file_as_string(DARTBOARD_FLASH_LOG).strip_edges()
		_finish_dartboard_update(false, log_text if log_text != "" else "udg-dartboard-flash exited with code %s" % rc)
		return

	_set_status("Waiting for the DartBoard Interface to restart...")
	waited = 0.0
	while waited < DARTBOARD_PORT_WAIT_S and OS.execute("test", ["-e", DARTBOARD_PORT]) != 0:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
	if waited >= DARTBOARD_PORT_WAIT_S:
		_finish_dartboard_update(false, "%s did not reappear (the board may be stuck in BOOTSEL, run the update again)" % DARTBOARD_PORT)
		return

	var new_version := _read_alive_version()
	if new_version == _pending_target_version:
		_finish_dartboard_update(true, "DartBoard Interface updated to v%s." % new_version)
	elif new_version == "":
		_finish_dartboard_update(false, "no answer to `alive` after the update")
	else:
		_finish_dartboard_update(false, "board reports v%s, expected v%s" % [new_version, _pending_target_version])

func _finish_dartboard_update(success: bool, message: String) -> void:
	_set_busy(false)
	_set_status(message if success else "DartBoard Interface update failed: %s" % message)

func _set_status(text: String) -> void:
	status_label.text = text
