use byteorder::ReadBytesExt;
use bytes::{BufMut, BytesMut};
use core::borrow::Borrow;
use futures::future::{err, ok};
use futures::{Future, IntoFuture};
use interledger_packet::{oer::BufOerExt, ErrorCode, PrepareBuilder, RejectBuilder};
use interledger_packet::{Fulfill, Prepare, Reject};
use interledger_service::*;
use std::convert::TryFrom;
use std::marker::PhantomData;
use std::net::Incoming;
use std::str;
use std::time::Duration;

/// A service that responds to the Echo Protocol.

/// The prefix that echo packets should have in its data section
const ECHO_PREFIX: &str = "ECHOECHOECHOECHO";
/// Echo packets should have at least this size of data in its data section
/// - 16 = `ECHOECHOECHOECHO`
/// - 1 = size of echo packet type, echo packet type is either `0` or `1` (1 byte)
const MIN_DATA_SIZE: usize = 16 + 1;

enum EchoPacketType {
    Request = 0,
    Response = 1,
}

#[derive(Clone)]
pub struct EchoService<S, A> {
    next_incoming: S,
    account_type: PhantomData<A>,
}

// TODO triggered by
impl<S, A> EchoService<S, A>
where
    S: IncomingService<A>,
    A: Account,
{
    pub fn new(next_incoming: S) -> Self {
        EchoService {
            next_incoming,
            account_type: PhantomData,
        }
    }

    fn get_error_response(
        &self,
        error_code: ErrorCode,
        message: &str,
        triggered_by: &[u8],
        data: &[u8],
    ) -> BoxedIlpFuture {
        let result = RejectBuilder {
            code: error_code,
            message: message.as_bytes(),
            triggered_by,
            data,
        }
        .build();
        return Box::new(err(result));
    }

    fn get_packet_too_short_error(&self, length: usize) -> BoxedIlpFuture {
        return self.get_error_response(
            ErrorCode::F01_INVALID_PACKET,
            format!("packet data too short for echo request. length={}", length).as_str(),
            self.get_own_address().as_bytes(),
            &[],
        );
    }

    fn get_invalid_prefix_error(&self) -> BoxedIlpFuture {
        return self.get_error_response(
            ErrorCode::F01_INVALID_PACKET,
            "packet data does not start with ECHO prefix.",
            self.get_own_address().as_bytes(),
            &[],
        );
    }

    fn get_unexpected_echo_response_error(&self) -> BoxedIlpFuture {
        return self.get_error_response(
            ErrorCode::F01_INVALID_PACKET,
            "unexpected echo response.",
            self.get_own_address().as_bytes(),
            &[],
        );
    }

    /// returns the connector's address
    fn get_own_address(&self) -> &str {
        // FIXME
        return "";
    }
}

impl<S, A> IncomingService<A> for EchoService<S, A>
where
    S: IncomingService<A>,
    A: Account,
{
    type Future = BoxedIlpFuture;

    fn handle_request(&mut self, mut request: IncomingRequest<A>) -> Self::Future {
        let should_echo = request.prepare.destination() == self.get_own_address().as_bytes();
        if !should_echo {
            return Box::new(self.next_incoming.handle_request(request));
        }

        let suffices_min_length = MIN_DATA_SIZE <= request.prepare.data().len();
        if !suffices_min_length {
            return self.get_packet_too_short_error(request.prepare.data().len());
        }

        let starts_with_echo_prefix = request.prepare.data().starts_with(ECHO_PREFIX.as_bytes());
        if !starts_with_echo_prefix {
            return self.get_invalid_prefix_error();
        }

        let mut reader = request.prepare.data();
        reader.skip(ECHO_PREFIX.len()).ok();
        let echo_packet_type = reader.read_u8().unwrap();
        let source_address = reader.read_var_octet_string().unwrap();

        let is_packet_type_request = echo_packet_type == EchoPacketType::Request as u8;
        if !is_packet_type_request {
            return self.get_unexpected_echo_response_error();
        }

        let mut data_buffer = BytesMut::with_capacity(1024);
        data_buffer.put(ECHO_PREFIX.as_bytes());
        data_buffer.put_u8(EchoPacketType::Response as u8);

        // change prepare parameters to be routed as appropriate
        request.prepare.set_destination(source_address);
        request
            .prepare
            .set_expires_at(request.prepare.expires_at() - Duration::from_millis(1000));
        request.prepare.set_data(data_buffer.borrow());

        return Box::new(self.next_incoming.handle_request(request));
    }
}
