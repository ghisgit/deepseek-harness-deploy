#!/usr/bin/env node
/**
 * TCP forwarder for the dsh deployment image.
 *
 * dsh >= 0.2.1 rejects wildcard bind addresses and dsh 0.2.0 cannot bind a
 * concrete interface at all, so the harness itself always listens on
 * 127.0.0.1 inside the container. This forwarder is the only listener on the
 * container's own interface, so the compose port publish (which targets the
 * container address) reaches dsh without the harness ever binding the
 * network. It is a transparent TCP relay: HTTP, WebSocket upgrades and
 * keep-alive connections pass through unchanged, and the browser's Host
 * header still drives dsh's /api browser-trust fence.
 *
 * Usage: node dsh-forward.mjs <listen-host> <listen-port> <target-host> <target-port>
 */
import net from "node:net"

const [listenHost, listenPort, targetHost, targetPort] = process.argv.slice(2)

if (!listenHost || !listenPort || !targetHost || !targetPort) {
    console.error("dsh-forward: usage: dsh-forward.mjs <listen-host> <listen-port> <target-host> <target-port>")
    process.exit(2)
}

const port = Number(listenPort)
const upstreamPort = Number(targetPort)
if (!Number.isInteger(port) || !Number.isInteger(upstreamPort)) {
    console.error("dsh-forward: listen and target ports must be integers")
    process.exit(2)
}

const server = net.createServer((client) => {
    const upstream = net.connect(upstreamPort, targetHost)
    const teardown = () => {
        client.destroy()
        upstream.destroy()
    }
    client.on("error", teardown)
    upstream.on("error", teardown)
    client.pipe(upstream)
    upstream.pipe(client)
})

server.on("error", (error) => {
    console.error(`dsh-forward: ${error.message}`)
    process.exit(1)
})

server.listen(port, listenHost, () => {
    console.log(`dsh-forward: ${listenHost}:${port} -> ${targetHost}:${upstreamPort}`)
})
