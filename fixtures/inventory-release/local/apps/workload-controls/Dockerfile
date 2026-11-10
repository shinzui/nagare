# workload-controls: one image, three entrypoints (web, worker, migration).
FROM python:3.12-slim
RUN pip install --no-cache-dir "psycopg[binary]"
WORKDIR /app
COPY app.py worker.py migrate.py .
EXPOSE 8080
CMD ["python", "app.py"]
