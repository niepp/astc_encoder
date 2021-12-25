 real time ASTC texture compression by computer shader 

用d3d compute shader实时压缩astc纹理，支持ASTC4x4  6x6，带alpha通道，法线贴图

# 依赖

- d3d11

- [Stbimage](https://github.com/nothings/stb) - for image loading

# 使用格式

| 命令参数 | 可选值 | 作用                     |
| -------- | ------ | ------------------------ |
| -4x4     | 1 or 0 | 是否使用ASTC4x4，否则6x6 |
| -alpha   | 1 or 0 | 是否有alpha通道          |
| -norm    | 1 or 0 | 是否法线贴图             |

例子

astc_cs_enc.exe ./textures/leaf.png -alpha 1 4x4 1

