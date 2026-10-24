"""A man in the middle for the TLS 1.2 section of bench/std_tls_exercise.sh.

    python3 bench/std_tls12_proxy.py PORTFILE UPSTREAM_PORT MODE

Listens on 127.0.0.1 (its port written to PORTFILE), takes one connection,
and relays it to 127.0.0.1:UPSTREAM_PORT - an honest TLS 1.2 server - with
one thing in the server's plaintext flight changed, by MODE:

    ske-signature   the ServerKeyExchange's last byte, inside its signature
    ske-point       a byte of the ServerKeyExchange's ECDHE point, which the
                    signature covers
    sentinel        the ServerHello's random ending in RFC 8446's TLS 1.2
                    downgrade sentinel
    none            nothing

Each must be refused by the client before it writes anything under keys.
Written for this one purpose: a record is changed only when the message
lies whole within it, as OpenSSL's flights do.
"""
import socket
import sys
import threading


def pipe(src, dst, change):
    buf = b""
    keyed = False
    try:
        while True:
            got = src.recv(65536)
            if not got:
                break
            buf += got
            out = b""
            while len(buf) >= 5 and len(buf) >= 5 + int.from_bytes(buf[3:5], "big"):
                size = 5 + int.from_bytes(buf[3:5], "big")
                record, buf = bytearray(buf[:size]), buf[size:]
                if record[0] == 20:
                    keyed = True
                if change and record[0] == 22 and not keyed:
                    change(record)
                out += bytes(record)
            if out:
                dst.sendall(out)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def messages(record):
    """(offset, type, length) of each handshake message whole in the record."""
    at = 5
    while at + 4 <= len(record):
        length = int.from_bytes(record[at + 1:at + 4], "big")
        if at + 4 + length > len(record):
            return
        yield at, record[at], length
        at += 4 + length


def main():
    mode = sys.argv[3]

    def change(record):
        for at, kind, length in messages(record):
            if mode == "ske-signature" and kind == 12:
                record[at + 4 + length - 1] ^= 1
            elif mode == "ske-point" and kind == 12:
                record[at + 4 + 4 + 1] ^= 1
            elif mode == "sentinel" and kind == 2:
                record[at + 4 + 2 + 24:at + 4 + 2 + 32] = b"DOWNGRD\x01"

    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    open(sys.argv[1], "w").write(str(listener.getsockname()[1]))
    client, _ = listener.accept()
    server = socket.create_connection(("127.0.0.1", int(sys.argv[2])))
    up = threading.Thread(target=pipe, args=(client, server, None))
    up.start()
    pipe(server, client, None if mode == "none" else change)
    up.join()


if __name__ == "__main__":
    main()
