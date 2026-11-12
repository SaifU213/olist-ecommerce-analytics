"""Render docs/OlistAnalytics-report.pdf to docs/screenshots/, cropped to the report canvas.

Cropping drops any Desktop side pane captured in the export and trims empty canvas.
Usage: python docs/render_screenshots.py [pdf] [out_dir]
"""
import sys
import numpy as np
import pypdfium2 as pdfium
from PIL import Image

pdf_path = sys.argv[1] if len(sys.argv) > 1 else "docs/OlistAnalytics-report.pdf"
out_dir = sys.argv[2] if len(sys.argv) > 2 else "docs/screenshots"
names = ["01-overview", "02-customers", "03-delivery-reviews", "04-products-sellers", "05-retention-segments"]
CANVAS = np.array([243, 245, 248])
PAD = 20

for name, page in zip(names, pdfium.PdfDocument(pdf_path)):
    im = page.render(scale=2).to_pil().convert("RGB")
    a = np.asarray(im).astype(int)
    is_canvas = (np.abs(a - CANVAS).sum(axis=2) <= 6)
    # canvas rectangle = rows/cols that are mostly canvas-coloured somewhere
    ys, xs = np.where(is_canvas)
    cx0, cx1, cy0, cy1 = xs.min(), xs.max(), ys.min(), ys.max()
    # content inside canvas = anything not canvas-coloured
    inner = ~is_canvas[cy0:cy1 + 1, cx0:cx1 + 1]
    rows = np.where(inner.mean(axis=1) > 0.002)[0]
    cols = np.where(inner.mean(axis=0) > 0.002)[0]
    x0 = max(cx0, cx0 + cols.min() - PAD); x1 = min(cx1 + 1, cx0 + cols.max() + 1 + PAD)
    y0 = max(cy0, cy0 + rows.min() - PAD); y1 = min(cy1 + 1, cy0 + rows.max() + 1 + PAD)
    out = im.crop((x0, y0, x1, y1))
    out.save(f"{out_dir}/{name}.png", optimize=True)
    print(name, "canvas", (cx0, cy0, cx1, cy1), "->", out.size)
