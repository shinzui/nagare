# The content-app probe (MasterPlan 39): Google's storage client, unchanged, behind a tiny HTTP server.
FROM docker.io/library/python:3.12-slim
RUN pip install --no-cache-dir google-cloud-storage==3.17.2
COPY server.py /srv/server.py
USER 65532:65532
EXPOSE 8080
CMD ["python", "/srv/server.py"]
