## About

real time ASTC texture compression by computer shader 

用d3d compute shader实时压缩astc纹理，实现的是ASTC的一个子集。

## Features
- texture compress in realtime
- astc4x4
- astc6x6
- alpha channel
- normal map
- compress in linear space

## Dependencies

- [d3d11](https://docs.microsoft.com/en-us/windows/win32/api/_direct3d11/)

- [stb_image.h](https://github.com/nothings/stb/blob/master/stb_image.h) -   for image loading

## Release

[astc_encoder v1.0](https://github.com/niepp/astc_encoder/releases/download/V1.0/astc_cs_enc.7z)

## Usage

astc_cs_enc.exe  input_texture option_args

| command parameter | valid value | explanation                    |
| ----------------- | ----------- | ------------------------------ |
| -4x4              | 1 or 0      | use format ASTC4x4，or ASTC6x6 |
| -alpha            | 1 or 0      | does have alpha channel        |
| -norm             | 1 or 0      | whether or not normal map      |

 example

``` bash
astc_cs_enc.exe ./textures/leaf.png -alpha 1 4x4 1
```

see more https://niepp.github.io/2021/12/18/Compute-ASTC.html
