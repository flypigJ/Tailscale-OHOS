import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';

const PORT: number = 48719;

/** Bounded loopback stream. Received bytes are counted and immediately discarded. */
export class SimulatedDownload {
  private server?: socket.TCPSocketServer;
  private sender?: socket.TCPSocketConnection;
  private receiver?: socket.TCPSocket;
  private timer: number = -1;
  private epoch: number = 0;
  private sending: boolean = false;
  private received: number = 0;

  async start(progress: (bytes: number) => void, failed: (code: number) => void): Promise<void> {
    await this.stop();
    const epoch: number = ++this.epoch;
    this.received = 0;
    const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
    this.server = server;
    server.on('error', (error: BusinessError) => {
      if (epoch === this.epoch) failed(error.code ?? -1);
    });
    server.on('connect', (client: socket.TCPSocketConnection) => {
      if (epoch !== this.epoch || this.sender !== undefined) {
        void client.close().catch(() => {});
        return;
      }
      this.sender = client;
      const payload: ArrayBuffer = new ArrayBuffer(4096);
      client.on('error', (error: BusinessError) => {
        if (epoch === this.epoch) failed(error.code ?? -1);
      });
      client.on('close', () => {
        if (epoch === this.epoch) failed(-1);
      });
      this.timer = setInterval(() => {
        if (epoch !== this.epoch || this.sending) return;
        this.sending = true;
        client.send({ data: payload }).catch((error: BusinessError) => {
          if (epoch === this.epoch) failed(error.code ?? -1);
        }).finally(() => { if (epoch === this.epoch) this.sending = false; });
      }, 1000);
    });
    const useDynamicPort: boolean = typeof server.getLocalAddress === 'function';
    await server.listen({ address: '127.0.0.1', port: useDynamicPort ? 0 : PORT, family: 1 });
    if (epoch !== this.epoch) return;
    const listenPort: number = useDynamicPort ? ((await server.getLocalAddress()).port ?? PORT) : PORT;
    if (epoch !== this.epoch) return;
    const receiver: socket.TCPSocket = socket.constructTCPSocketInstance();
    this.receiver = receiver;
    receiver.on('message', (message: socket.SocketMessageInfo) => {
      if (epoch !== this.epoch) return;
      this.received += message.message.byteLength;
      progress(this.received);
    });
    receiver.on('error', (error: BusinessError) => {
      if (epoch === this.epoch) failed(error.code ?? -1);
    });
    receiver.on('close', () => {
      if (epoch === this.epoch) failed(-1);
    });
    await receiver.bind({ address: '127.0.0.1', port: 0, family: 1 });
    if (epoch !== this.epoch) return;
    await receiver.connect({ address: { address: '127.0.0.1', port: listenPort, family: 1 }, timeout: 3000 });
  }

  async stop(): Promise<void> {
    this.epoch++;
    if (this.timer >= 0) clearInterval(this.timer);
    this.timer = -1;
    this.sending = false;
    const receiver: socket.TCPSocket | undefined = this.receiver;
    const sender: socket.TCPSocketConnection | undefined = this.sender;
    const server: socket.TCPSocketServer | undefined = this.server;
    this.receiver = undefined;
    this.sender = undefined;
    this.server = undefined;
    if (receiver !== undefined) {
      receiver.off('message'); receiver.off('error'); receiver.off('close');
      try { await receiver.close(); } catch (_error) {}
    }
    if (sender !== undefined) {
      sender.off('error'); sender.off('close');
      try { await sender.close(); } catch (_error) {}
    }
    if (server !== undefined) {
      server.off('connect'); server.off('error');
      try { await server.close(); } catch (_error) {}
    }
  }
}
