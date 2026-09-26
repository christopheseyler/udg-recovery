class_name RecoveryScreen
extends Control

## Ecran de recovery : point d'entree de l'application udg-recovery. Repris
## de l'ecran de reglages du jeu (udg-test, settings_screen) : une seule
## fonctionnalite, la mise a jour de l'application depuis une cle USB (voir
## meta-udg dans udg-test / udg-yocto pour le pipeline RAUC app-only A/B).
##
## "Check for update from USB" liste tous les fichiers .raucb trouves dans
## UPDATE_DIR (la cle USB est montee - ou son contenu copie - a ce chemin
## fixe, /media/udg-update) et laisse choisir lequel installer - plusieurs
## versions peuvent cohabiter sur la meme cle (ex. pour revenir en
## arriere). Sur selection, lit sa version via `rauc info`, puis demande
## confirmation ("Application vX.Y.Z, Do you want to upgrade?"). Sur
## confirmation, `udg-app-selector.sh --install` tourne dans un thread (ca
## peut prendre du temps) ; une fois termine avec succes, le meme dialogue
## est reutilise pour proposer un redemarrage (udg-app-selector.sh reprend
## la main au prochain demarrage et bascule sur le nouveau slot) - voir
## _confirm_action, qui distingue les deux usages du dialogue.
##
## Le bouton "Reboot" permet de quitter la recovery sans mise a jour.
##
## PAS `rauc install` directement : bootloader=noop empeche RAUC de
## determiner seul le slot inactif, donc il installerait toujours dans le
## meme slot. udg-app-selector.sh --install verifie la signature puis ecrit
## dans le slot que l'etat systeme sait etre inactif.
##
## Suppose que quelque chose (udev/systemd, hors scope de ce script) monte
## deja la cle USB sur ce chemin fixe : ce script ne monte rien lui-meme.
## Sans le binaire `rauc` ni ce point de montage (ex. en test dans
## l'editeur sous Windows), se degrade proprement sur "No update found".

## Chemin fixe ou la cle USB de mise a jour est attendue montee (convention
## retenue avec l'equipe systeme, voir doc de classe ci-dessus).
const UPDATE_DIR := "/media/udg-update"
const BUNDLE_EXTENSION := ".raucb"

## Ce que "Yes" declenche dans le dialogue de confirmation, partage entre
## la confirmation d'upgrade et la proposition de redemarrage qui suit une
## installation reussie.
enum ConfirmAction { NONE, UPGRADE, REBOOT }

@onready var check_update_button: Button = $Panel/Layout/Margin/Content/CheckUpdateButton
@onready var status_label: Label = $Panel/Layout/Margin/Content/StatusLabel
@onready var bundle_scroll: ScrollContainer = $Panel/Layout/Margin/Content/BundleScroll
@onready var bundle_list: VBoxContainer = $Panel/Layout/Margin/Content/BundleScroll/BundleList
@onready var reboot_button: Button = $Panel/Layout/Margin/Content/RebootButton
@onready var confirm_overlay: Control = $ConfirmOverlay
@onready var confirm_label: Label = $ConfirmOverlay/Center/Dialog/Margin/Content/ConfirmLabel
@onready var no_button: Button = $ConfirmOverlay/Center/Dialog/Margin/Content/Buttons/NoButton
@onready var yes_button: Button = $ConfirmOverlay/Center/Dialog/Margin/Content/Buttons/YesButton

var _pending_bundle_path := ""
var _install_thread: Thread
var _confirm_action := ConfirmAction.NONE

func _ready() -> void:
	check_update_button.pressed.connect(_on_check_update_pressed)
	reboot_button.pressed.connect(_on_reboot_pressed)
	no_button.pressed.connect(_on_confirm_no)
	yes_button.pressed.connect(_on_confirm_yes)
	bundle_scroll.visible = false

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

	var bundle_paths := _find_bundles()
	if bundle_paths.is_empty():
		_set_status("No update found on USB.")
		return

	_set_status("Found %d update(s) on USB. Choose one:" % bundle_paths.size())
	for path in bundle_paths:
		var button := Button.new()
		button.text = path.get_file()
		button.custom_minimum_size = Vector2(0, 90)
		button.add_theme_font_size_override("font_size", 32)
		button.pressed.connect(_on_bundle_selected.bind(path))
		bundle_list.add_child(button)
	bundle_scroll.visible = true

func _clear_bundle_list() -> void:
	bundle_scroll.visible = false
	for child in bundle_list.get_children():
		bundle_list.remove_child(child)
		child.queue_free()

## Liste tous les fichiers .raucb directement sous UPDATE_DIR, tries par
## nom. Renvoie un tableau vide si le dossier n'existe pas (pas de cle
## montee) ou ne contient aucun bundle.
func _find_bundles() -> Array[String]:
	var paths: Array[String] = []
	var dir := DirAccess.open(UPDATE_DIR)
	if dir == null:
		return paths

	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.ends_with(BUNDLE_EXTENSION):
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
	_confirm_action = ConfirmAction.UPGRADE
	confirm_label.text = "Application v%s\nDo you want to upgrade?" % info.version
	confirm_overlay.visible = true

## Lit le manifeste du bundle via `rauc info` (verifie sa structure, pas sa
## signature : `udg-app-selector.sh --install` la verifiera de toute facon).
func _read_bundle_info(path: String) -> Dictionary:
	var output := []
	var exit_code := OS.execute("rauc", ["info", path], output, true)
	if exit_code != 0:
		return {"ok": false, "error": "rauc info exited with code %d" % exit_code}

	var text: String = output[0] if output.size() > 0 else ""
	var version := _extract_field(text, "Version")
	if version == "":
		return {"ok": false, "error": "no version field in bundle manifest"}
	return {"ok": true, "version": version, "compatible": _extract_field(text, "Compatible")}

func _extract_field(text: String, field_name: String) -> String:
	var regex := RegEx.new()
	regex.compile("%s:\\s*'([^']*)'" % field_name)
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
			_start_install()
		ConfirmAction.REBOOT:
			OS.execute("systemctl", ["reboot"])

func _start_install() -> void:
	_set_status("Installing update, please wait...")
	check_update_button.disabled = true
	reboot_button.disabled = true

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
	reboot_button.disabled = false

	if exit_code == 0:
		_set_status("Update installed. Restart to switch to the new version.")
		_confirm_action = ConfirmAction.REBOOT
		confirm_label.text = "Update installed.\nRestart now?"
		confirm_overlay.visible = true
	else:
		check_update_button.disabled = false
		_set_status("Update failed: %s" % log_text)

func _set_status(text: String) -> void:
	status_label.text = text
