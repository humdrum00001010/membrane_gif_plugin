use std::borrow::Cow;

use yuv::{YuvBiPlanarImage, YuvPackedImage, YuvPlanarImage};
use yuv::{YuvConversionMode, YuvRange, YuvStandardMatrix};

// RawVideo has no colorimetry fields. YUV inputs use limited-range BT.601.
const YUV_RANGE: YuvRange = YuvRange::Limited;
const YUV_MATRIX: YuvStandardMatrix = YuvStandardMatrix::Bt601;

macro_rules! pixel_formats {
    ($($variant:ident => ($atom:literal, $bytes:literal / $pixels:literal, $conversion:ident $args:tt)),+ $(,)?) => {
        #[derive(Clone, Copy, Debug)]
        pub enum PixelFormat {
            $($variant),+
        }

        impl PixelFormat {
            pub fn frame_size(self, width: u16, height: u16) -> usize {
                let area = usize::from(width) * usize::from(height);
                let (bytes_per_group, pixels_per_group) = match self {
                    $(Self::$variant => ($bytes, $pixels)),+
                };
                area * bytes_per_group / pixels_per_group
            }

            pub fn to_rgb(self, data: &[u8], width: u16, height: u16) -> Result<Cow<'_, [u8]>, String> {
                if data.len() != self.frame_size(width, height) {
                    return Err("invalid_frame_size".into());
                }
                match self {
                    $(Self::$variant => convert_pixels!($conversion $args; data, width, height)),+
                }
            }
        }

        #[cfg(not(test))]
        impl<'a> rustler::Decoder<'a> for PixelFormat {
            #[allow(non_snake_case)]
            fn decode(term: rustler::Term<'a>) -> rustler::NifResult<Self> {
                rustler::atoms! { $($variant = $atom),+ }

                let atom = term.decode::<rustler::Atom>()?;
                $(
                    if atom == $variant() {
                        return Ok(Self::$variant);
                    }
                )+
                Err(rustler::Error::BadArg)
            }
        }
    };
}

macro_rules! convert_pixels {
    (rgb(); $data:ident, $width:ident, $height:ident) => {
        Ok(Cow::Borrowed($data))
    };

    (packed($channels:literal, [$red:literal, $green:literal, $blue:literal]);
     $data:ident, $width:ident, $height:ident) => {{
        let mut rgb = Vec::with_capacity(usize::from($width) * usize::from($height) * 3);
        // Select RGB channels; alpha is discarded.
        for pixel in $data.chunks_exact($channels) {
            rgb.extend_from_slice(&[pixel[$red], pixel[$green], pixel[$blue]]);
        }
        Ok(Cow::Owned(rgb))
    }};

    (planar($convert:path, $horizontal:literal, $vertical:literal, [$u:literal, $v:literal], $channels:literal);
     $data:ident, $width:ident, $height:ident) => {{
        let (width, height) = (u32::from($width), u32::from($height));
        let (horizontal, vertical) = ($horizontal, $vertical);
        let area = width as usize * height as usize;
        let mut rgb = vec![0; area * $channels];
        let chroma_width = width / horizontal;
        let chroma_height = height / vertical;
        let (y, chroma) = $data.split_at(area);
        let (first, second) = chroma.split_at(chroma_width as usize * chroma_height as usize);
        let planes = [first, second];
        let image = YuvPlanarImage {
            y_plane: y,
            y_stride: width,
            u_plane: planes[$u],
            u_stride: chroma_width,
            v_plane: planes[$v],
            v_stride: chroma_width,
            width,
            height,
        };
        $convert(&image, &mut rgb, width * $channels, YUV_RANGE, YUV_MATRIX)
            .map_err(|error| error.to_string())?;
        Ok::<Cow<'_, [u8]>, String>(Cow::Owned(rgb))
    }};

    (planar10($convert:path, $horizontal:literal, $vertical:literal);
     $data:ident, $width:ident, $height:ident) => {{
        // Copy into aligned words while preserving the input byte order.
        // The selected yuv converter interprets those words as LE or BE.
        let samples: Vec<u16> = $data
            .chunks_exact(size_of::<u16>())
            .map(|bytes| u16::from_ne_bytes([bytes[0], bytes[1]]))
            .collect();
        let rgba = convert_pixels!(
            planar($convert, $horizontal, $vertical, [0, 1], 4);
            samples, $width, $height
        )?;
        convert_pixels!(packed(4, [0, 1, 2]); rgba, $width, $height)
    }};

    (biplanar($convert:path); $data:ident, $width:ident, $height:ident) => {{
        let (width, height) = (u32::from($width), u32::from($height));
        let area = width as usize * height as usize;
        let mut rgb = vec![0; area * 3];
        let (y, uv) = $data.split_at(area);
        let image = YuvBiPlanarImage {
            y_plane: y,
            y_stride: width,
            uv_plane: uv,
            uv_stride: width,
            width,
            height,
        };
        $convert(
            &image,
            &mut rgb,
            width * 3,
            YUV_RANGE,
            YUV_MATRIX,
            YuvConversionMode::Balanced,
        )
        .map_err(|error| error.to_string())?;
        Ok(Cow::Owned(rgb))
    }};

    (packed_yuv($convert:path, $channels:literal $(, $extra:expr)*);
     $data:ident, $width:ident, $height:ident) => {{
        let (width, height) = (u32::from($width), u32::from($height));
        let mut rgb = vec![0; width as usize * height as usize * 3];
        let image = YuvPackedImage {
            yuy: $data,
            yuy_stride: width * $channels,
            width,
            height,
        };
        $convert(&image, &mut rgb, width * 3, YUV_RANGE, YUV_MATRIX $(, $extra)*)
            .map_err(|error| error.to_string())?;
        Ok(Cow::Owned(rgb))
    }};
}

// Rustler 0.34's NifUnitEnum derives lowercase atoms; Membrane uses these exact names.
pixel_formats! {
    I420 => ("I420", 3 / 2, planar(yuv::yuv420_to_rgb, 2, 2, [0, 1], 3)),
    I422 => ("I422", 2 / 1, planar(yuv::yuv422_to_rgb, 2, 1, [0, 1], 3)),
    I444 => ("I444", 3 / 1, planar(yuv::yuv444_to_rgb, 1, 1, [0, 1], 3)),
    Rgb => ("RGB", 3 / 1, rgb()),
    Bgr => ("BGR", 3 / 1, packed(3, [2, 1, 0])),
    Rgba => ("RGBA", 4 / 1, packed(4, [0, 1, 2])),
    Bgra => ("BGRA", 4 / 1, packed(4, [2, 1, 0])),
    Nv12 => ("NV12", 3 / 2, biplanar(yuv::yuv_nv12_to_rgb)),
    Nv21 => ("NV21", 3 / 2, biplanar(yuv::yuv_nv21_to_rgb)),
    Yuy2 => ("YUY2", 2 / 1, packed_yuv(yuv::yuyv422_to_rgb, 2)),
    Yv12 => ("YV12", 3 / 2, planar(yuv::yuv420_to_rgb, 2, 2, [1, 0], 3)),
    Ayuv => ("AYUV", 4 / 1, packed_yuv(yuv::ayuv_to_rgb, 4, false)),
    I42010Le => ("I420_10LE", 3 / 1, planar10(yuv::i010_to_rgba, 2, 2)),
    I42010Be => ("I420_10BE", 3 / 1, planar10(yuv::i010_be_to_rgba, 2, 2)),
    I42210Le => ("I422_10LE", 4 / 1, planar10(yuv::i210_to_rgba, 2, 1)),
    I42210Be => ("I422_10BE", 4 / 1, planar10(yuv::i210_be_to_rgba, 2, 1)),
    I44410Le => ("I444_10LE", 6 / 1, planar10(yuv::i410_to_rgba, 1, 1)),
    I44410Be => ("I444_10BE", 6 / 1, planar10(yuv::i410_be_to_rgba, 1, 1)),
}
