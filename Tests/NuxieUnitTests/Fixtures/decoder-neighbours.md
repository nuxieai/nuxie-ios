# Image decoder neighbours

These `.bin` resources preserve the original encoded bytes. Apple's PNG resource copier can rewrite `.png` files, which would change the representation under test.

The PNGs have two pixels and one unfiltered row. Expected native bytes are sRGB RGBA with each straight colour channel multiplied by its own alpha once and rounded to 8 bits. Browser canvas samples over black independently agree with their premultiplied RGB values.

| File | Encoded samples or palette entries | Expected native RGBA |
| --- | --- | --- |
| decoder-indexed-opaque | PLTE (17,34,51), (255,64,32), indices 0,1; no tRNS | (17,34,51,255), (255,64,32,255) |
| decoder-truecolor-alpha | RGBA (17,34,51,255), (255,64,32,180) | (17,34,51,255), (180,45,23,180) |
| decoder-grayscale-alpha | Grey/alpha (85,255), (204,128) | (85,85,85,255), (102,102,102,128) |
| decoder-16bit-alpha | RGBA (4369,8738,13107,65535), (65535,16448,8224,46260) | (17,34,51,255), (180,45,23,180) |
| decoder-jpeg | Constant 8 by 8 neutral RGB block (128,128,128), quality 100, no chroma subsampling | (128,128,128,255) at every pixel |
| decoder-indexed-profile-alpha | PLTE (17,34,51), (255,64,32); tRNS 255,180; embedded sRGB ICC profile | (17,34,51,255), (180,45,23,180) |

For example, the translucent red pixel gives red 255*180/255=180, green round(64*180/255)=45 and blue round(32*180/255)=23. The 16-bit samples are the corresponding 8-bit values multiplied by 257. The greyscale sample gives round(204*128/255)=102 in each colour channel. The JPEG's constant block has a zero level-shifted DC coefficient and no AC coefficients, so it decodes to neutral 128.
