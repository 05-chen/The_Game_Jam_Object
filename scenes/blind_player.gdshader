shader_type canvas_item;
// 瞎子视野：屏幕下方半圆孔透明（显示 3D），孔外纯黑遮罩。
// 参考 Godot Screen-reading / CanvasItem 混合：孔内 alpha=0 透传视口，孔外 alpha=1 叠黑色。
render_mode unshaded;

uniform float vision_radius : hint_range(0.0, 1.0) = 0.22;
uniform float feather : hint_range(0.0, 0.1) = 0.06;
// 半圆平直边所在的纵向位置（SCREEN_UV：1.0 = 屏幕最底）
uniform float vision_bottom_y : hint_range(0.0, 1.0) = 0.94;

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 center = vec2(0.5, vision_bottom_y);
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	vec2 delta = uv - center;
	delta.x *= aspect;
	float dist = length(delta);

	// 1.0 = 遮罩外（全黑），0.0 = 视野内（完全透明）
	float arc_occlusion = smoothstep(vision_radius, vision_radius + feather, dist);
	float flat_occlusion = smoothstep(vision_bottom_y - feather * 0.35, vision_bottom_y + feather * 0.35, uv.y);
	float occlusion = clamp(max(arc_occlusion, flat_occlusion), 0.0, 1.0);

	COLOR = vec4(0.0, 0.0, 0.0, occlusion);
}
