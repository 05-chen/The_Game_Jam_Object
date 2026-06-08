shader_type canvas_item;
// 圆孔内：Alpha=0 透出完整 3D；圆孔外：环境压纯黑，仅保留高亮物品（高亮度/emission）幽灵轮廓
render_mode unshaded, blend_mix;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform float vision_radius : hint_range(0.0, 1.0) = 0.15;
uniform float feather : hint_range(0.0, 1.0) = 0.1;
uniform vec2 vision_center = vec2(0.5, 0.62);
uniform float ghost_lum_threshold : hint_range(0.0, 1.0) = 0.16;
uniform float ghost_lum_softness : hint_range(0.01, 0.5) = 0.14;

void fragment() {
	vec2 uv = SCREEN_UV;
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	vec2 delta = uv - vision_center;
	delta.x *= aspect;
	float dist = length(delta);
	float mask = smoothstep(vision_radius, vision_radius + feather, dist);

	vec3 scene = texture(screen_texture, uv).rgb;
	float lum = max(max(scene.r, scene.g), scene.b);
	float ghost = smoothstep(ghost_lum_threshold, ghost_lum_threshold + ghost_lum_softness, lum);

	vec3 outside_col = mix(vec3(0.0), scene, ghost);
	vec3 final_col = mix(scene, outside_col, mask);
	COLOR = vec4(final_col, mask);
}
