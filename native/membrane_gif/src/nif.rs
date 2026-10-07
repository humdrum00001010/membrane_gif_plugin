use std::sync::Mutex;

use rustler::{Atom, Binary, Env, NifResult, OwnedBinary, ResourceArc, Term};

use crate::encoder::Encoder;
use crate::pixels::PixelFormat;

#[derive(rustler::NifException)]
#[module = "RuntimeError"]
struct RuntimeError {
    message: String,
}

#[derive(rustler::NifUnitEnum)]
enum Disposal {
    Keep,
    Background,
}

// ResourceArc provides shared access; the GIF writer requires exclusive mutable access.
struct EncoderResource(Mutex<Encoder>);

#[derive(rustler::NifMap)]
struct CreateOptions {
    width: u64,
    height: u64,
    pixel_format: Atom,
    r#loop: Option<u64>,
    disposal: Disposal,
}

#[allow(non_local_definitions)]
fn load(env: Env, _info: Term) -> bool {
    rustler::resource!(EncoderResource, env)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn create(options: CreateOptions) -> NifResult<ResourceArc<EncoderResource>> {
    let format = PixelFormat::from_atom(options.pixel_format).ok_or(rustler::Error::BadArg)?;
    let disposal = match options.disposal {
        Disposal::Keep => gif::DisposalMethod::Keep,
        Disposal::Background => gif::DisposalMethod::Background,
    };
    let encoder = Encoder::new(
        options.width,
        options.height,
        format,
        options.r#loop,
        disposal,
    )
    .map_err(|_| rustler::Error::BadArg)?;
    Ok(ResourceArc::new(EncoderResource(Mutex::new(encoder))))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn encode<'a>(
    env: Env<'a>,
    resource: ResourceArc<EncoderResource>,
    pixels: Binary,
    delay_cs: u64,
) -> NifResult<Binary<'a>> {
    let delay_cs = u16::try_from(delay_cs).map_err(|_| rustler::Error::BadArg)?;
    let output = resource
        .0
        .lock()
        .map_err(|_| rustler::Error::BadArg)?
        .encode(&pixels, delay_cs);
    output_binary(env, output)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn finish<'a>(env: Env<'a>, resource: ResourceArc<EncoderResource>) -> NifResult<Binary<'a>> {
    let output = resource
        .0
        .lock()
        .map_err(|_| rustler::Error::BadArg)?
        .finish();
    output_binary(env, output)
}

fn output_binary(env: Env, output: Result<Vec<u8>, gif::EncodingError>) -> NifResult<Binary> {
    let bytes = output.map_err(|error| {
        rustler::Error::RaiseTerm(Box::new(RuntimeError {
            message: error.to_string(),
        }))
    })?;

    let mut payload = OwnedBinary::new(bytes.len()).ok_or(rustler::Error::BadArg)?;
    payload.as_mut_slice().copy_from_slice(&bytes);
    Ok(payload.release(env))
}

rustler::init!("Elixir.Membrane.GIF.Encoder.Native", load = load);
