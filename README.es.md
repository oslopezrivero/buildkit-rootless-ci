# BuildKit rootless para GitLab CI

*[Read in English](README.md)*

Construí imágenes de contenedores en GitLab CI **sin jobs privilegiados y sin el socket de Docker del host**.

Docker-in-Docker es la receta habitual, pero necesita `privileged: true` (o montar `/var/run/docker.sock`).
En la práctica, cualquiera que pueda pushear una rama puede ejecutar código con control casi total del
servidor del runner y de todo lo que corre ahí.

Este repositorio es una configuración de referencia, chica y probada, que lo reemplaza:

```
 GitLab Runner (privileged = false, sin docker.sock)
   ├─ jobs grupo A ──mTLS (CA A)──▶ buildkitd-team-a ─┐
   └─ jobs grupo B ──mTLS (CA B)──▶ buildkitd-team-b ─┴─▶ registry
```

- **Un demonio BuildKit rootless por grupo** de proyectos, en su propia red de Docker y sin puertos publicados.
- **TLS mutuo con una CA por grupo.** El certificado de cliente del grupo A es rechazado por el BuildKit del grupo B.
- **Runners sin privilegios**: `privileged = false`, sin `docker.sock`.
- **Un componente de CI/CD reutilizable**: cada proyecto lo incluye en pocas líneas y las mejoras se hacen una sola vez.
- **Un script de auditoría** que detecta pipelines que vuelven a Docker-in-Docker.

## Contenido

| Ruta | Qué es |
|---|---|
| `buildkitd/docker-compose.yml` | `buildkitd` rootless para un grupo (límites de recursos, healthcheck, sin puertos) |
| `buildkitd/gen-certs.sh` | Crea la CA del grupo y los certificados de servidor y cliente |
| `templates/buildkit-build.yml` | Componente de GitLab CI/CD: build y push con `buildctl` por mTLS, con caché en el registry |
| `gitlab/config.toml.example` | Sección del runner: sin privilegios, sin socket, en la red del grupo |
| `scripts/audit-dind.py` | Revisa los archivos de CI buscando `docker:dind`, `privileged: true`, el socket de Docker y `docker build` |
| `test/` | Prueba de punta a punta en un Docker local, más casos para la auditoría |

## Inicio rápido

```bash
cd buildkitd
sudo ./gen-certs.sh team-a                    # certs/ para buildkitd-team-a
GROUP=team-a docker compose up -d --wait      # demonio en la red team-a-ci
```

Después:

1. Conectá el runner del grupo a esa red (`network_mode = "team-a-ci"`, ver `gitlab/config.toml.example`).
2. Cargá variables de CI/CD del grupo: `BUILDKIT_HOST=tcp://buildkitd-team-a:1234`, y `BUILDKIT_CA_PEM`,
   `BUILDKIT_CLIENT_CERT`, `BUILDKIT_CLIENT_KEY` como variables de tipo **File** con `ca.pem`, `client.pem` y `client-key.pem`.
3. Publicá `templates/buildkit-build.yml` como componente del catálogo e incluilo:

```yaml
include:
  - component: $CI_SERVER_FQDN/platform/buildkit-rootless-ci/buildkit-build@1
    inputs:
      dockerfile: docker/app.Dockerfile
```

Repetí con otro nombre de grupo para cada equipo: CA, red y límites separados.

## Probarlo

```bash
test/run.sh     # necesita Docker; no deja nada instalado
test/audit.sh   # no necesita Docker
```

`test/run.sh` levanta dos demonios con CAs distintas y comprueba que:

1. el grupo A construye una imagen por mTLS,
2. la imagen y su caché se suben a un registry con los mismos parámetros que el componente,
3. el BuildKit del grupo B rechaza el certificado de cliente del grupo A.

## Lo aprendido

1. **Migrá por etapas.** Un grupo primero, estabilizalo y después seguí.
2. **Revisá los permisos del registry.** Compartir demonio o caché entre proyectos puede hacer que BuildKit
   intente montar capas entre repos, algo que el token del job no tiene permitido. El registry responde
   `insufficient_scope`, que no explica la causa. Usá un demonio por grupo, o agregá los proyectos que
   consumen a la allowlist del job token del proyecto de origen.
3. **Vigilá que no vuelva.** Las plantillas copiadas de internet traen Docker-in-Docker. Corré
   `scripts/audit-dind.py` de forma programada sobre tus repositorios.
4. **Cuidá las alertas.** Una alerta que está siempre en rojo no la mira nadie. Que la auditoría falle solo
   por las ramas que importan (main, release) y el resto quede como reporte.

## Notas

- `--oci-worker-no-process-sandbox` junto con `seccomp=unconfined` / `apparmor=unconfined` es la forma en que
  la imagen rootless oficial corre sin contenedor privilegiado. Los builds siguen corriendo en un user namespace sin privilegios.
- En una red de runner fija, los alias de `services:` de GitLab no resuelven, así que `docker:dind` deja de funcionar
  ahí. Es a propósito.
- Guardá `ca-key.pem` fuera de línea. Para rotar, regenerá los certificados del grupo y actualizá sus variables de CI.

## Autor

Omar López Rivero, Infrastructure & Platform Lead.
[LinkedIn](https://www.linkedin.com/in/omar-salvador-l%C3%B3pez-rivero-023718136/)

Licencia MIT.
