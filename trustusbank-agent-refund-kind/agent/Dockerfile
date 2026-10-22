FROM python:3.12-slim
RUN pip install --no-cache-dir 'PyJWT[crypto]==2.10.1' 'mcp==1.17.0' 'pydantic==2.11.9'
COPY server.py /app/server.py
COPY chat_tools.py /app/chat_tools.py
CMD ["python", "/app/server.py"]
