ARG BASE_IMAGE=docker.io/library/python:3.12-alpine
FROM ${BASE_IMAGE}

COPY probe.py /usr/local/bin/nsair-ci-seccomp-notify-concurrency-probe
RUN chmod +x /usr/local/bin/nsair-ci-seccomp-notify-concurrency-probe

ENTRYPOINT ["nsair-ci-seccomp-notify-concurrency-probe"]
