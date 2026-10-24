FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /build
ENV MAVEN_OPTS="-Xmx512m"
COPY backend/fiis/pom.xml ./pom.xml
COPY backend/fiis/src ./src
RUN mvn -B -ntp -DskipTests package

FROM eclipse-temurin:17-jre-alpine
RUN apk add --no-cache curl \
    && addgroup -g 10001 app \
    && adduser -D -u 10001 -G app app \
    && mkdir -p /app/uploads-fiis \
    && chown -R app:app /app
WORKDIR /app
COPY --from=build --chown=app:app /build/target/fiis-0.0.1-SNAPSHOT.jar /app/app.jar
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
