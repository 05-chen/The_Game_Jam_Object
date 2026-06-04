shader_type canvas_item;
// blend_mix：中心 Alpha=0 透出已渲染的 3D 画面（聚光灯高亮物品）；边缘 Alpha=1 纯黑遮罩
render_mode unshaded, blend_mix;

uniform float vision_radius : hint_range(0.0, 1.0) = 0.15;
uniform float feather : hint_range(0.0, 1.0) = 0.1;
// 圆孔中心（屏幕 UV）；默认略偏下，与「中下方小圆孔」一致；脚本仍只驱动 vision_radius
uniform vec2 vision_center = vec2(0.5, 0.62);

void fragment() {
	vec2 uv = SCREEN_UV;
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	vec2 delta = uv - vision_center;
	delta.x *= aspect;
	float dist = length(delta);
	float mask = smoothstep(vision_radius, vision_radius + feather, dist);
	COLOR = vec4(0.0, 0.0, 0.0, clamp(mask, 0.0, 1.0));
}