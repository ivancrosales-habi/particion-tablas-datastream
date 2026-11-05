# Entorno: `bq` y `gcloud` en Windows con IPv6 roto

**Síntoma:** `bq` o `gcloud` se cuelgan unos 20 segundos por conexión, o dan timeout.

**Causa:** la red anuncia IPv6 pero no lo enruta, y el Python que trae el SDK de Google Cloud intenta IPv6 primero.

**Arreglo, sin permisos de administrador:**
1. Copia `sitecustomize.py` a la carpeta de paquetes del Python del SDK:
   ```powershell
   Copy-Item .\entorno\sitecustomize.py "$env:LOCALAPPDATA\Google\Cloud SDK\google-cloud-sdk\platform\bundledpython\Lib\site-packages\sitecustomize.py"
   ```
2. En cada ventana de PowerShell, o como variable de usuario:
   ```powershell
   $env:CLOUDSDK_PYTHON_SITEPACKAGES = '1'
   ```
   Sin esta variable, `bq` arranca Python con `-S` y no carga el archivo.

Un `gcloud components update` puede borrar el archivo. Si vuelven a colgarse, cópialo otra vez.

Para deshacer el arreglo: borra el archivo y la variable.
