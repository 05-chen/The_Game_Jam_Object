shader_type canvas_item;
// 半圆视野：平直边贴在屏幕下方，弧顶向上（Godot SCREEN_UV：y=0 顶，y=1 底）
render_mode unshaded, blend_mix;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform float vision_radius : hint_range(0.0, 1.0) = 0.22;
uniform float feather : hint_range(0.0, 1.0) = 0.06;
// 半圆平直边所在的纵向位置（1.0=屏幕最底，越大越靠下）
uniform float vision_bottom_y : hint_range(0.0, 1.0) = 0.94;
uniform float ghost_lum_threshold : hint_range(0.0, 1.0) = 0.10;
uniform float ghost_lum_softness : hint_range(0.01, 0.5) = 0.20;

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 center = vec2(0.5, vision_bottom_y);
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	vec2 delta = uv - center;
	delta.x *= aspect;
	float dist = length(delta);

	// 圆外 → 遮罩
	float arc_mask = smoothstep(vision_radius, vision_radius + feather, dist);
	// 平直边以下 → 遮罩（只保留圆心以上的半圆，即屏幕下方拱形孔）
	float flat_mask = smoothstep(vision_bottom_y - feather * 0.35, vision_bottom_y + feather * 0.35, uv.y);
	float mask = max(arc_mask, flat_mask);

	vec3 scene = texture(screen_texture, uv).rgb;
	float lum = max(max(scene.r, scene.g), scene.b);
	float ghost = smoothstep(ghost_lum_threshold, ghost_lum_threshold + ghost_lum_softness, lum);

	vec3 outside_col = mix(vec3(0.0), scene, ghost);
	vec3 final_col = mix(scene, outside_col, mask);
	COLOR = vec4(final_col, mask);
}
