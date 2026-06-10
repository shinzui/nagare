# clickhouse-analytics: a tiny stdlib HTTP app + the clickhouse-driver client.
FROM python:3.12-slim
RUN pip install --no-cache-dir clickhouse-driver
WORKDIR /app
COPY app.py .
EXPOSE 8080
CMD ["python", "app.py"]
