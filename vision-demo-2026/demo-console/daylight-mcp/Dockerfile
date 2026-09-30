FROM python:3.12-alpine
RUN apk add --no-cache tzdata
COPY daylight_mcp.py /app/daylight_mcp.py
EXPOSE 3000
CMD ["python3", "/app/daylight_mcp.py"]
