FROM python:3.12-slim
RUN pip install --no-cache-dir 'PyJWT[crypto]==2.10.1'
COPY server.py /app/server.py
CMD ["python", "/app/server.py"]
