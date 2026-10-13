# Image decoder neighbours

These `.bin` resources preserve the original encoded bytes. Apple's PNG resource copier can rewrite `.png` files, which would change the representation under test.

The original neighbour PNGs have two pixels and one unfiltered row. Packed palette fixtures have four pixels per row; the interlaced fixture repeats that row four times through the seven Adam7 passes. Expected native bytes are sRGB RGBA with each straight colour channel multiplied by its own alpha once and rounded to 8 bits. Browser canvas samples over black independently agree with their premultiplied RGB values.

| File | Encoded samples or palette entries | Expected native RGBA |
| --- | --- | --- |
| decoder-indexed-opaque | PLTE (17,34,51), (255,64,32), indices 0,1; no tRNS | (17,34,51,255), (255,64,32,255) |
| decoder-truecolor-alpha | RGBA (17,34,51,255), (255,64,32,180) | (17,34,51,255), (180,45,23,180) |
| decoder-grayscale-alpha | Grey/alpha (85,255), (204,128) | (85,85,85,255), (102,102,102,128) |
| decoder-16bit-alpha | RGBA (4369,8738,13107,65535), (65535,16448,8224,46260) | (17,34,51,255), (180,45,23,180) |
| decoder-jpeg | Constant 8 by 8 neutral RGB block (128,128,128), quality 100, no chroma subsampling | (128,128,128,255) at every pixel |
| decoder-indexed-profile-alpha | PLTE (17,34,51), (255,64,32); tRNS 255,180; embedded sRGB ICC profile | (17,34,51,255), (180,45,23,180) |

For example, the translucent red pixel gives red 255*180/255=180, green round(64*180/255)=45 and blue round(32*180/255)=23. The 16-bit samples are the corresponding 8-bit values multiplied by 257. The greyscale sample gives round(204*128/255)=102 in each colour channel. The JPEG's constant block has a zero level-shifted DC coefficient and no AC coefficients, so it decodes to neutral 128.

| Additional file | Encoded samples | Expected native RGBA |
| --- | --- | --- |
| decoder-indexed-2bit-alpha | 2-bit indices 0,1,2,3, packed as 0x1b; PLTE repeats (255,64,32); tRNS 0,64,128,255 | (0,0,0,0), (64,16,8,64), (128,32,16,128), (255,64,32,255) |
| decoder-indexed-4bit-alpha | Same entries, 4-bit indices packed as 0x01,0x23 | Same four pixels |
| decoder-indexed-interlaced-alpha | Same 2-bit row repeated at y=0,1,2,3, interlace method 1 (Adam7) | Same four pixels on every row |
| decoder-indexed-display-p3-alpha | Embedded Display P3 ICC; PLTE (128,128,128), (255,128,0); tRNS 128,180 | (64,64,64,128), (180,84,0,180), tolerance 1 for ICC rounding |

Display P3 uses the sRGB transfer curve. Linearizing (255,128,0), multiplying by the Display P3 to sRGB primary matrix, clipping to the sRGB gamut and applying the transfer curve gives approximately (255,119,0). Multiplication by 180/255 gives (180,84,0). Neutral grey retains its channels and gives round(128*128/255)=64. This expectation comes from the encoded profile and source colours, independently of ImageIO output.

`translucent-indexed-green.bin` retains the original 512 by 512 palette PNG without Apple's PNG resource copying. Its straight palette entry is (0,255,0), with tRNS alpha 180. The central native pixel must be (0,180,0,180).
