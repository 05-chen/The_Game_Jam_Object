shader_type canvas_item;

// 1. 默认半径设为 0.5（大洞），这样即便脚本没运行，预览也不该是黑的
uniform float vision_radius : hint_range(0.0, 1.0) = 0.15;
uniform float feather : hint_range(0.0, 1.0) = 0.1;
uniform vec2 screen_size = vec2(1920.0, 1080.0);

void fragment() {
    vec2 uv = SCREEN_UV;
    
    // 防止 screen_size 为 0 导致的计算崩溃
    vec2 res = screen_size;
    if (res.x <= 0.0 || res.y <= 0.0) {
        res = vec2(1920.0, 1080.0); 
    }

    float aspect = res.x / res.y;
    vec2 aspect_uv = (uv - vec2(0.5)) * vec2(aspect, 1.0) + vec2(0.5);
    
    float dist = distance(aspect_uv, vec2(0.5));
    
    // 核心计算
    float mask = smoothstep(vision_radius, vision_radius + feather, dist);
    
    // 输出：RGB纯黑，Alpha控制透明度
    COLOR = vec4(0.0, 0.0, 0.0, clamp(mask, 0.0, 1.0));
}