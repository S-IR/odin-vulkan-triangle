package main


Available_Shaders :: enum {
	TriangleVert,
	TriangleFrag,
}
Available_Shader_Binaries :: #partial [Available_Shaders][]byte {
	.TriangleVert = #load("./../assets/shader-binaries/shader.vert.spv"),
	.TriangleFrag = #load("./../assets/shader-binaries/shader.frag.spv"),
}
