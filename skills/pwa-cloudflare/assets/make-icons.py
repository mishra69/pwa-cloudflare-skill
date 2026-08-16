#!/usr/bin/env python3
"""Generate Sudoku app icons as PNGs with no third-party deps.

Draws a 3x3 grid (legible at 180px in a way a full 9x9 grid is not) with a
white diagonal and two lighter accent cells, on the app's brand blue.
Backgrounds are fully opaque: iOS renders alpha in an apple-touch-icon as black.
"""
import struct
import zlib
import os

BG     = tuple(int(os.environ.get('ICON_BG', '59,130,246').split(',')[i]) for i in range(3))
LINE   = (255, 255, 255)
ACCENT = (147, 197, 253)   # #93c5fd

OUT = os.environ.get('ICON_OUT', os.path.join(os.getcwd(), 'icons'))


class Canvas:
    def __init__(self, size, bg):
        self.size = size
        self.px = bytearray(bg * (size * size))

    def rect(self, x0, y0, x1, y1, color):
        x0, y0 = max(0, int(x0)), max(0, int(y0))
        x1, y1 = min(self.size, int(x1)), min(self.size, int(y1))
        row = bytes(color) * (x1 - x0)
        for y in range(y0, y1):
            start = (y * self.size + x0) * 3
            self.px[start:start + len(row)] = row

    def png(self, path):
        raw = bytearray()
        stride = self.size * 3
        for y in range(self.size):
            raw.append(0)  # filter: none
            raw.extend(self.px[y * stride:(y + 1) * stride])

        def chunk(tag, data):
            out = struct.pack('>I', len(data)) + tag + data
            return out + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF)

        ihdr = struct.pack('>IIBBBBB', self.size, self.size, 8, 2, 0, 0, 0)
        blob = (b'\x89PNG\r\n\x1a\n'
                + chunk(b'IHDR', ihdr)
                + chunk(b'IDAT', zlib.compress(bytes(raw), 9))
                + chunk(b'IEND', b''))
        with open(path, 'wb') as f:
            f.write(blob)


def draw(size, pad_frac):
    c = Canvas(size, BG)
    pad = size * pad_frac
    inner = size - 2 * pad
    cell = inner / 3.0
    t = max(1.0, inner * 0.028)         # grid line thickness
    inset = cell * 0.20                 # keeps filled blocks off the lines

    # White board.
    c.rect(pad, pad, pad + inner, pad + inner, LINE)

    # Filled cells: blue diagonal with two lighter accents.
    def block(col, row, color):
        c.rect(pad + col * cell + inset, pad + row * cell + inset,
               pad + (col + 1) * cell - inset, pad + (row + 1) * cell - inset, color)

    for i in range(3):
        block(i, i, BG)
    block(2, 0, ACCENT)
    block(0, 2, ACCENT)

    # Grid: two internal lines on each axis (the board edge needs no border,
    # the blue background already supplies one).
    for i in (1, 2):
        off = pad + i * cell - t / 2
        c.rect(pad, off, pad + inner, off + t, BG)  # horizontal
        c.rect(off, pad, off + t, pad + inner, BG)  # vertical
    return c


os.makedirs(OUT, exist_ok=True)
# apple-touch-icon: iOS squircle-crops the corners, so keep content inset.
draw(180, 0.12).png(os.path.join(OUT, 'apple-touch-icon.png'))
draw(192, 0.10).png(os.path.join(OUT, 'icon-192.png'))
draw(512, 0.10).png(os.path.join(OUT, 'icon-512.png'))
# maskable: safe zone is the middle 80%, so pad harder.
draw(512, 0.20).png(os.path.join(OUT, 'icon-maskable-512.png'))

for f in sorted(os.listdir(OUT)):
    print(f, os.path.getsize(os.path.join(OUT, f)), 'bytes')
