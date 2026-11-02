# Graphic Layer Separator — OpenCV v0.1

Deployment target: GitHub repository ivanzep/PROT, folder image-layer-separator.

## Application files
Copy the supplied v0.1 files into this folder:
- app.py
- index.html
- requirements.txt

## Backend deployment
1. In Render, create a Blueprint using this repository and render.yaml.
2. Confirm the Python web service deploys.
3. The v0.1 FastAPI application serves both the HTML UI and the API from the same origin. Use the Render service URL for a working application.
4. GitHub Pages cannot execute Python; hosting the frontend there requires changing the frontend API URLs and configuring CORS on FastAPI. This is not configured in v0.1.

## Limitations
- In-memory sessions are lost when Render restarts.
- OpenCV segmentation is based on contrast, not semantic understanding.
- PSD output is raster layers, not editable vector/text objects.
- Test PSD export with your Photoshop version before production use.
