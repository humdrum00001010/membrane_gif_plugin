use gif::{DisposalMethod, Frame, Repeat};

use crate::pixels::PixelFormat;

pub struct Encoder {
    width: u16,
    height: u16,
    format: PixelFormat,
    loop_count: Option<u16>,
    writer: Option<gif::Encoder<Vec<u8>>>,
}

impl Encoder {
    pub fn new(width: u16, height: u16, format: PixelFormat, loop_count: Option<u16>) -> Self {
        Self {
            width,
            height,
            format,
            loop_count,
            writer: None,
        }
    }

    pub fn encode(&mut self, pixels: &[u8], delay_cs: u16) -> Result<Vec<u8>, String> {
        let rgb = self.format.to_rgb(pixels, self.width, self.height)?;
        let mut frame = Frame::from_rgb_speed(self.width, self.height, &rgb, 10);
        frame.dispose = DisposalMethod::Keep;
        frame.delay = delay_cs;
        if self.writer.is_none() {
            let mut writer = gif::Encoder::new(Vec::new(), self.width, self.height, &[])
                .map_err(|error| error.to_string())?;
            if let Some(count) = self.loop_count {
                let repeat = if count == 0 {
                    Repeat::Infinite
                } else {
                    Repeat::Finite(count)
                };
                writer
                    .set_repeat(repeat)
                    .map_err(|error| error.to_string())?;
            }
            self.writer = Some(writer);
        }
        let writer = self.writer.as_mut().expect("writer was initialized");
        writer
            .write_frame(&frame)
            .map_err(|error| error.to_string())?;
        // Drain each chunk; the writer never retains earlier GIF bytes.
        Ok(std::mem::take(writer.get_mut()))
    }

    pub fn finish(&mut self) -> Result<Vec<u8>, String> {
        match self.writer.take() {
            Some(writer) => writer.into_inner().map_err(|error| error.to_string()),
            None => Ok(Vec::new()),
        }
    }
}

#[cfg(test)]
mod tests;
