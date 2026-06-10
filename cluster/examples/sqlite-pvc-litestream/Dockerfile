# sqlite-pvc-litestream example image (EP-37): a tiny stdlib Python HTTP server
# that keeps a SQLite database on the durable /data volume. No third-party deps.
FROM python:3.12-alpine
WORKDIR /app
COPY app.py ./
EXPOSE 8080
CMD ["python3", "app.py"]
