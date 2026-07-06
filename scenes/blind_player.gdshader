shader_type canvas_item;
// 半圆孔：平直边在 vision_center 水平线，弧向上；孔外压黑，高亮物品幽灵透出
render_mode unshaded, blend_mix;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform float vision_radius : hint_range(0.0, 1.0) = 0.18;
uniform float feather : hint_range(0.0, 1.0) = 0.08;
// 半圆直径中点：屏幕水平正中、偏下方（y 越大越靠屏幕底部）
uniform vec2 vision_center = vec2(0.5, 0.68);
uniform float ghost_lum_threshold : hint_range(0.0, 1.0) = 0.16;
uniform float ghost_lum_softness : hint_range(0.01, 0.5) = 0.14;

void fragment() {
	vec2 uv = SCREEN_UV;
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	vec2 delta = uv - vision_center;
	delta.x *= aspect;
	float dist = length(delta);

	// 圆弧外缘羽化
	float arc_mask = smoothstep(vision_radius, vision_radius + feather, dist);
	// 半圆：裁掉圆心下方（平直边在 vision_center.y）
	float flat_mask = smoothstep(vision_center.y - feather * 0.35, vision_center.y + feather * 0.35, uv.y);
	float mask = max(arc_mask, flat_mask);

	vec3 scene = texture(screen_texture, uv).rgb;
	float lum = max(max(scene.r, scene.g), scene.b);
	float ghost = smoothstep(ghost_lum_threshold, ghost_lum_threshold + ghost_lum_softness, lum);

	vec3 outside_col = mix(vec3(0.0), scene, ghost);
	vec3 final_col = mix(scene, outside_col, mask);
	COLOR = vec4(final_col, mask);
}
