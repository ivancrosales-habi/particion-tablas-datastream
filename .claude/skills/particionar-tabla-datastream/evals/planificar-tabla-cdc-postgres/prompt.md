---
tags: [particionar-tabla-datastream]
max_turns: 20
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill]
---

hola, me toca particionar una tabla nueva: habi-datalakehouse-ocd.pg_sellers.oportunidades, la escribe un stream de datastream que viene de postgres (cloud sql). la tabla tiene primary key (id_oportunidad) y el stream está en modo merge. pesa unos 80 GB y las consultas filtran por fecha_creacion (TIMESTAMP). quiero partición por día. ¿cuál es el plan y qué tengo que revisar antes? no ejecutes nada todavía.