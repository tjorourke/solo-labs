FROM python:3.12-slim
RUN pip install --no-cache-dir mcp==1.26.0
WORKDIR /app
COPY server.py test_server.py /app/
RUN python -m unittest test_server
USER 10001
EXPOSE 3000
CMD ["python", "-u", "/app/server.py"]
