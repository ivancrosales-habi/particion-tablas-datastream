---
tags: [particionar-tabla-datastream]
max_turns: 20
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill]
---

ya hice el drop y el rename, la tabla broker_activity quedó particionada. corrí el script de permisos y me sale:

  FALTA roles/bigquery.dataViewer | serviceAccount:buyers-mx-dwh-hour-sa@papyrus-master.iam.gserviceaccount.com
  FALTA roles/bigquery.dataViewer | user:usuario.lector@habi.co
== Accesos del dataset co_habi_brokers
  OK    Idénticos (38 entradas)

el stream sigue pausado. ¿puedo reanudar el datastream sin tener esos permisos o tengo que esperar al admin?