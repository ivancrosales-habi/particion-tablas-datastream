---
tags: [particionar-tabla-datastream]
max_turns: 20
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill]
---

estoy en plena ventana particionando brokers-main-prod.co_habi_brokers.broker (stream habi-brokers-co). ya pausé el stream, el buffer está vacío, copié a broker_nueva y las huellas del paso 8 dieron iguales. al correr el paso de renombrar me salió esto:

Invalid value: Cannot rename brokers-main-prod:co_habi_brokers.broker because it has streaming data. at [1:1]

las 46 tablas co_ están congeladas, ¿qué hago? no ejecutes nada tú, solo dime los pasos.