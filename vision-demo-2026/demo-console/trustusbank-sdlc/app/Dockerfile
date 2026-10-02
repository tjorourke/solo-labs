FROM python:3.12-alpine
ARG GIT_SHA=dev
ENV GIT_SHA=${GIT_SHA} PYTHONUNBUFFERED=1
WORKDIR /app
COPY server.py config.json /app/
COPY static /app/static
COPY site /app/site
EXPOSE 8080
USER 65534
CMD ["python3", "/app/server.py"]
