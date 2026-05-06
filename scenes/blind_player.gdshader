shader_type canvas_item;
// 与默认 blend_mix 一致；不采样 TEXTURE，避免 ColorRect 默认纹理参与乘色（见官方 CanvasItem fragment 说明）
render_mode unshaded;

// 默认半径：脚本未运行时预览仍可见
uniform float vision_radius : hint_range(0.0, 1.0) = 0.15;
uniform float feather : hint_range(0.0, 1.0) = 0.1;

void fragment() {
	vec2 uv = SCREEN_UV;
	// 官方 CanvasItem fragment 内置：SCREEN_PIXEL_SIZE = 分辨率倒数量级，用于把 SCREEN_UV 拉回“像素等比例”空间，使洞为圆形（不依赖 GDScript 传 viewport 尺寸，避免拉伸/改分辨率后未及时更新）
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	vec2 aspect_uv = (uv - vec2(0.5)) * vec2(aspect, 1.0) + vec2(0.5);
    
	float dist = distance(aspect_uv, vec2(0.5));
	float mask = smoothstep(vision_radius, vision_radius + feather, dist);
	// RGB 纯黑，Alpha 为暗角强度（与视口中心“隧道视野”一致）
	COLOR = vec4(0.0, 0.0, 0.0, clamp(mask, 0.0, 1.0));
}