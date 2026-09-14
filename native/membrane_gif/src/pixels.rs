use gif::Frame;

/// Pixel formats accepted by the `gif` crate. Any other input format
/// should be converted upstream, e.g. with membrane_ffmpeg_swscale_plugin.
#[derive(Clone, Copy, Debug)]
pub enum PixelFormat {
    Rgb,
    Rgba,
}

#[derive(Debug, PartialEq, Eq)]
pub enum PixelError {
    InvalidFrameSize,
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

    pub fn frame_size(self, width: u16, height: u16) -> usize {
        let channels = match self {
            Self::Rgb => 3,
            Self::Rgba => 4,
        };
        usize::from(width) * usize::from(height) * channels
    }

    pub fn convert(
        self,
        width: u16,
        height: u16,
        pixels: &[u8],
    ) -> Result<Frame<'static>, PixelError> {
        if pixels.len() != self.frame_size(width, height) {
            return Err(PixelError::InvalidFrameSize);
        }

        Ok(match self {
            Self::Rgb => Frame::from_rgb_speed(width, height, pixels, 10),
            Self::Rgba => {
                let mut rgba = pixels.to_vec();
                let mut frame = Frame::from_rgba_speed(width, height, &mut rgba, 10);
                reserve_transparency(&mut frame);
                frame
            }
        })
    }
}

fn reserve_transparency(frame: &mut Frame<'static>) {
    if frame.transparent.is_some() {
        return;
    }

    // Background disposal must have a transparent index to clear this frame
    // before the next one, even when every source pixel is opaque.
    let palette = frame.palette.as_mut().expect("RGBA frames have a palette");
    let colors = palette.len() / 3;
    if colors < 256 {
        frame.transparent = Some(colors as u8);
        palette.extend_from_slice(&[0, 0, 0]);
        return;
    }

    let mut counts = [0usize; 256];
    for &index in frame.buffer.iter() {
        counts[index as usize] += 1;
    }

    let victim = counts
        .iter()
        .enumerate()
        .min_by_key(|(_, count)| *count)
        .unwrap()
        .0;
    if counts[victim] > 0 {
        // A full 256-color palette must give up one color for transparency.
        let replacement = (0..256)
            .filter(|&index| index != victim)
            .min_by_key(|&index| {
                (0..3)
                    .map(|channel| {
                        let distance = i32::from(palette[victim * 3 + channel])
                            - i32::from(palette[index * 3 + channel]);
                        distance * distance
                    })
                    .sum::<i32>()
            })
            .unwrap();

        for index in frame.buffer.to_mut() {
            if usize::from(*index) == victim {
                *index = replacement as u8;
            }
        }
    }
    frame.transparent = Some(victim as u8);
}
