const { createRequire } = require('node:module');

function registerPresence(grpc, service, destination) {
  const presence = { Join: service.Join, Alive: service.Alive };
  const Client = grpc.makeGenericClientConstructor(presence, 'WorkerPresence');
  const upstream = new Client(destination, grpc.credentials.createInsecure());
  const server = new grpc.Server();

  function publicError(error) {
    return Object.assign(new Error('OASM worker presence request failed'), {
      code: error.code ?? grpc.status.UNAVAILABLE,
    });
  }

  // Paths stay those of WorkersService. The gateway exposes only presence RPCs.
  server.addService(presence, {
    Join(call, reply) {
      const request = upstream.Join(call.request, { deadline: Date.now() + 5000 }, (error, result) => {
        if (error) reply(publicError(error));
        else reply(null, result);
      });
      call.once('cancelled', () => request.cancel());
    },
    Alive(call) {
      const stream = upstream.Alive(call.request);
      call.once('cancelled', () => stream.cancel());
      call.on('drain', () => stream.resume());
      stream.on('data', response => {
        if (!call.cancelled && !call.write(response)) stream.pause();
      });
      stream.once('end', () => call.end());
      stream.once('error', error => {
        if (!call.cancelled) call.destroy(publicError(error));
      });
    },
  });

  return { server, upstream };
}

if (require.main === module) {
  const requireApi = createRequire('/app/package.json');
  const grpc = requireApi('@grpc/grpc-js');
  const loader = createRequire(requireApi.resolve('@grpc/grpc-js'))('@grpc/proto-loader');
  const proto = loader.loadSync('/app/dist/proto/workers.proto');
  const { service } = grpc.loadPackageDefinition(proto).workers.WorkersService;
  const { server, upstream } = registerPresence(grpc, service, 'core-api:16276');

  server.bindAsync('0.0.0.0:16276', grpc.ServerCredentials.createInsecure(), error => {
    if (error) {
      upstream.close();
      console.error('Worker check gateway could not bind');
      process.exitCode = 1;
      return;
    }
    console.log('Worker check gateway ready for Join and Alive');
  });

  for (const signal of ['SIGINT', 'SIGTERM']) {
    process.once(signal, () => {
      server.forceShutdown();
      upstream.close();
    });
  }
}

module.exports = { registerPresence };
