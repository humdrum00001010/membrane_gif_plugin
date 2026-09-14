use std::num::TryFromIntError;

use gif::{DisposalMethod, Repeat};

use crate::pixels::{PixelError, PixelFormat};

#[derive(Debug, PartialEq, Eq)]
pub enum EncodeError {
    Pixel(PixelError),
    Writer(String),
}

pub struct Encoder {
    width: u16,
    height: u16,
    format: PixelFormat,
    loop_count: Option<u16>,
    writer: Option<gif::Encoder<Vec<u8>>>,
}

impl Encoder {
    pub fn new(
        width: u64,
        height: u64,
        format: PixelFormat,
        loop_count: Option<u64>,
    ) -> Result<Self, TryFromIntError> {
        let width = u16::try_from(width)?;
        let height = u16::try_from(height)?;
        let loop_count = loop_count.map(u16::try_from).transpose()?;
        Ok(Self {
            width,
            height,
            format,
            loop_count,
            writer: None,
        })
    }

    pub fn checked_delay(delay_cs: u64) -> Result<u16, TryFromIntError> {
        u16::try_from(delay_cs)
    }

    pub fn encode(&mut self, pixels: &[u8], delay_cs: u16) -> Result<Vec<u8>, EncodeError> {
        let mut frame = self
            .format
            .convert(self.width, self.height, pixels)
            .map_err(EncodeError::Pixel)?;
        frame.dispose = match self.format {
            PixelFormat::Rgb => DisposalMethod::Keep,
            PixelFormat::Rgba => DisposalMethod::Background,
        };
        frame.delay = delay_cs;
        if self.writer.is_none() {
            let mut writer = gif::Encoder::new(Vec::new(), self.width, self.height, &[])
                .map_err(|error| EncodeError::Writer(error.to_string()))?;
            if let Some(count) = self.loop_count {
                let repeat = if count == 0 {
                    Repeat::Infinite
                } else {
                    Repeat::Finite(count)
                };
                writer
                    .set_repeat(repeat)
                    .map_err(|error| EncodeError::Writer(error.to_string()))?;
            }
            self.writer = Some(writer);
        }
        let writer = self.writer.as_mut().expect("writer was initialized");
        writer
            .write_frame(&frame)
            .map_err(|error| EncodeError::Writer(error.to_string()))?;
        // Drain each chunk; the writer never retains earlier GIF bytes.
        Ok(std::mem::take(writer.get_mut()))
    }

    pub fn finish(&mut self) -> Result<Vec<u8>, EncodeError> {
        match self.writer.take() {
            Some(writer) => writer
                .into_inner()
                .map_err(|error| EncodeError::Writer(error.to_string())),
            None => Ok(Vec::new()),
        }
    }
}
