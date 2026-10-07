use gif::Frame;

/// Pixel formats accepted by the `gif` crate. Any other input format
/// should be converted upstream, e.g. with membrane_ffmpeg_swscale_plugin.
#[derive(Clone, Copy, Debug)]
pub enum PixelFormat {
    Rgb,
    Rgba,
}

impl PixelFormat {
    #[allow(non_snake_case)]
    pub fn from_atom(atom: rustler::Atom) -> Option<Self> {
        rustler::atoms! { Rgb = "RGB", Rgba = "RGBA" }

        if atom == Rgb() {
            Some(Self::Rgb)
        } else if atom == Rgba() {
            Some(Self::Rgba)
        } else {
            None
        }
    }

    pub fn convert(self, width: u16, height: u16, pixels: &[u8]) -> Frame<'static> {
        match self {
            Self::Rgb => Frame::from_rgb_speed(width, height, pixels, 10),
            Self::Rgba => {
                let mut rgba = pixels.to_vec();
                // GIF has no partial alpha: `gif` keeps A=0 transparent
                // and makes every nonzero A fully opaque.
                Frame::from_rgba_speed(width, height, &mut rgba, 10)
            }
        }
    }
}
