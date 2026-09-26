extends Control

## Ecran titre de l'application de recovery : meme fond et meme titre que
## le jeu (udg-test), le titre apparait en fondu, reste affiche, puis
## disparait en fondu avec un zoom accelere pendant que le background
## s'assombrit, avant de basculer directement vers l'ecran de recovery
## (qui demarre sur ce fond assombri). Un tap/clic saute a la suite.

@export var next_scene_path: String = "res://main_screens/recovery_screen/recovery_screen.tscn"
@export var start_delay: float = 1.0
@export var fade_in_duration: float = 1.5
@export var hold_duration: float = 2.0
@export var fade_out_duration: float = 1.0
@export var zoom_out_scale: float = 20.0
@export var background_dark_color: Color = Color(0.55, 0.55, 0.55, 1.0)

@onready var background: TextureRect = $Background
@onready var title_image: TextureRect = $TitleImage
@onready var version_label: Label = $VersionLabel

var _going_to_next_scene := false

func _ready() -> void:
	ResourceLoader.load_threaded_request(next_scene_path)
	_show_version()
	title_image.modulate.a = 0.0
	title_image.pivot_offset = title_image.size / 2.0
	title_image.resized.connect(func(): title_image.pivot_offset = title_image.size / 2.0)

	var tween := create_tween()
	tween.tween_interval(start_delay)
	tween.tween_property(title_image, "modulate:a", 1.0, fade_in_duration)
	tween.tween_interval(hold_duration)
	tween.tween_property(title_image, "modulate:a", 0.0, fade_out_duration)
	tween.parallel().tween_property(title_image, "scale", Vector2.ONE * zoom_out_scale, fade_out_duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(background, "modulate", background_dark_color, fade_out_duration)
	tween.tween_callback(_go_to_next_scene)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch and event.pressed:
		_go_to_next_scene()
	elif event is InputEventMouseButton and event.pressed:
		_go_to_next_scene()

## Affiche le numero de version du projet (config/version) en bas a droite,
## en italique synthetique (le projet n'embarque pas de police italique
## dediee pour ce style de texte).
func _show_version() -> void:
	var version: String = ProjectSettings.get_setting("application/config/version", "0.0.0")
	version_label.text = "Recovery v%s" % version

	var italic_font := FontVariation.new()
	italic_font.base_font = version_label.get_theme_default_font()
	italic_font.variation_transform = Transform2D(Vector2(1.0, 0.0), Vector2(0.22, 1.0), Vector2.ZERO)
	version_label.add_theme_font_override("font", italic_font)

func _go_to_next_scene() -> void:
	if _going_to_next_scene:
		return
	_going_to_next_scene = true

	while ResourceLoader.load_threaded_get_status(next_scene_path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await get_tree().process_frame
	get_tree().change_scene_to_packed(ResourceLoader.load_threaded_get(next_scene_path))
