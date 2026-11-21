# XV-Mesas — Kyara

Aplicación HTML estática para asignación de mesas de los XV años de Kyara. Abre index.html en el navegador o publícala mediante GitHub Pages.

## Datos

Importa un CSV o Excel con columnas **Nombre** y **Mesa**. Cada mesa redonda (2–15) permite hasta 10 invitados. También puedes pegar la URL CSV pública de Google Sheets, y pulsar **Vincular Google Sheets** para actualizar. Las personas de mesas fuera de 2–15 se omiten y se indica el recuento; excedentes se avisan y solo se imprimen los primeros 10 invitados.

## Impresión

**Imprimir / PDF** produce un diseño vertical de 24 × 36 pulgadas. En el diálogo del navegador, configura escala 100%, sin márgenes, y activa gráficos de fondo. Revisa la vista previa de impresión antes de enviar a imprenta.

La lista serpentina es una referencia gráfica, sin nombres asignados. El diseño visual usa HTML, SVG y CSS, sin recursos locales externos; utiliza Google Fonts y SheetJS CDN para las fuentes y los archivos Excel (CSV funciona sin SheetJS).
