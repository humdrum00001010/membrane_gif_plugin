use std::sync::Mutex;

use rustler::{Atom, Binary, Encoder as _, Env, NifResult, OwnedBinary, ResourceArc, Term};

use crate::encoder::{EncodeError, Encoder};
use crate::pixels::{PixelError, PixelFormat};

mod atoms {
    rustler::atoms! {
        ok
    }
}

// ResourceArc provides shared access; the GIF writer requires exclusive mutable access.
struct EncoderResource(Mutex<Encoder>);

#[derive(rustler::NifMap)]
struct CreateOptions {
    width: u64,
    height: u64,
    pixel_format: Atom,
    r#loop: Option<u64>,
}

#[allow(non_local_definitions)]
fn load(env: Env, _info: Term) -> bool {
    rustler::resource!(EncoderResource, env)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn create(env: Env, options: CreateOptions) -> NifResult<Term> {
    let format = PixelFormat::from_atom(options.pixel_format).ok_or(rustler::Error::BadArg)?;
    let encoder = Encoder::new(options.width, options.height, format, options.r#loop)
        .map_err(|_| rustler::Error::BadArg)?;
    Ok((
        atoms::ok(),
        ResourceArc::new(EncoderResource(Mutex::new(encoder))),
    )
        .encode(env))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn encode<'a>(
    env: Env<'a>,
    resource: ResourceArc<EncoderResource>,
    pixels: Binary,
    delay_cs: u64,
) -> NifResult<Term<'a>> {
    let delay_cs = Encoder::checked_delay(delay_cs).map_err(|_| rustler::Error::BadArg)?;
    let output = resource
        .0
        .lock()
        .map_err(|_| rustler::Error::BadArg)?
        .encode(&pixels, delay_cs);
    output_term(env, output)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn finish<'a>(env: Env<'a>, resource: ResourceArc<EncoderResource>) -> NifResult<Term<'a>> {
    let output = resource
        .0
        .lock()
        .map_err(|_| rustler::Error::BadArg)?
        .finish();
    output_term(env, output)
}

fn output_term(env: Env, output: Result<Vec<u8>, EncodeError>) -> NifResult<Term> {
    let bytes = output.map_err(|error| match error {
        EncodeError::Pixel(PixelError::InvalidFrameSize) => rustler::Error::BadArg,
        EncodeError::Writer(detail) => rustler::Error::RaiseTerm(Box::new(detail)),
    })?;

    let mut payload = OwnedBinary::new(bytes.len()).ok_or(rustler::Error::BadArg)?;
    payload.as_mut_slice().copy_from_slice(&bytes);
    Ok((atoms::ok(), payload.release(env)).encode(env))
}

rustler::init!("Elixir.Membrane.GIF.Encoder.Native", load = load);
