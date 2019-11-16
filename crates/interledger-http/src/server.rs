use super::{error::*, HttpStore};
use bytes::{buf::Buf, Bytes, BytesMut};
use futures::{
    future::{err, Either, FutureResult},
    Future,
};
use futures_locks::RwLockReadGuard;
use interledger_packet::{Address, Prepare};
use interledger_service::{
    AddressStore, AuthToken, IncomingRequest, IncomingService, RequestContext,
};
use log::error;
use std::{convert::TryFrom, net::SocketAddr};
use warp::{self, Filter, Rejection};

/// Max message size that is allowed to transfer from a request or a message.
pub const MAX_PACKET_SIZE: u64 = 40000;

/// A warp filter that parses incoming ILP-Over-HTTP requests, validates the authorization,
/// and passes the request to an IncomingService handler.
#[derive(Clone)]
pub struct HttpServer<I, S> {
    incoming: I,
    store: S,
}

impl<I, S> HttpServer<I, S>
where
    I: IncomingService<S::Account> + Clone + Send + Sync + 'static,
    S: HttpStore + AddressStore,
{
    pub fn new(incoming: I, store: S) -> Self {
        HttpServer { incoming, store }
    }

    pub fn as_filter(
        &self,
    ) -> impl warp::Filter<Extract = (warp::http::Response<Bytes>,), Error = warp::Rejection> + Clone
    {
        let incoming = self.incoming.clone();
        let store = self.store.clone();
        let with_store = warp::any().map(move || store.clone()).boxed();
        let with_ilp_address_lock = with_store
            .clone()
            .and_then(move |store: S| {
                store
                    .get_ilp_address_lock()
                    .read()
                    .map_err(|_| -> Rejection { ApiError::internal_server_error().into() })
            })
            .boxed();

        warp::post2()
            .and(warp::path("ilp"))
            .and(warp::path::end())
            .and(with_store.clone())
            .and(warp::header::<AuthToken>("authorization"))
            .and_then(move |store: S, auth: AuthToken| {
                store
                    .get_account_from_http_auth(auth.username(), auth.password())
                    .map_err(move |_| -> Rejection {
                        error!(
                            "Invalid authorization provided for user: {}",
                            auth.username()
                        );
                        ApiError::unauthorized().into()
                    })
            })
            .and(warp::body::content_length_limit(MAX_PACKET_SIZE))
            .and(warp::body::concat())
            .and(with_ilp_address_lock.clone())
            .and_then(
                move |account: S::Account,
                      body: warp::body::FullBody,
                      ilp_address_guard: RwLockReadGuard<Address>|
                      -> Either<_, FutureResult<_, Rejection>> {
                    // TODO don't copy ILP packet
                    let buffer = BytesMut::from(body.bytes());
                    let ilp_address = ilp_address_guard.clone();
                    let context = RequestContext::new(ilp_address);
                    if let Ok(prepare) = Prepare::try_from(buffer) {
                        Either::A(
                            incoming
                                .clone()
                                .handle_request(
                                    IncomingRequest {
                                        from: account,
                                        prepare,
                                    },
                                    context,
                                )
                                .then(move |result| {
                                    drop(ilp_address_guard);
                                    let bytes: BytesMut = match result {
                                        Ok(fulfill) => fulfill.into(),
                                        Err(reject) => reject.into(),
                                    };
                                    Ok(warp::http::Response::builder()
                                        .header("Content-Type", "application/octet-stream")
                                        .status(200)
                                        .body(bytes.freeze())
                                        .unwrap())
                                }),
                        )
                    } else {
                        drop(ilp_address_guard);
                        error!("Body was not a valid Prepare packet");
                        Either::B(err(ApiError::invalid_ilp_packet().into()))
                    }
                },
            )
    }

    pub fn bind(&self, addr: SocketAddr) -> impl Future<Item = (), Error = ()> + Send {
        warp::serve(self.as_filter()).bind(addr)
    }
}
