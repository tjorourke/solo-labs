# Built entirely in Docker, so no JDK or Maven is needed on the machine driving the demo.
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml .
RUN mvn -B -q -Dmaven.repo.local=/root/.m2 dependency:go-offline || true
COPY src ./src
RUN mvn -B -Dmaven.repo.local=/root/.m2 package -DskipTests

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /src/target/prtriage-java.jar /app/app.jar
# The same approved skill the Python agent bakes in. One skill, two languages.
COPY skill.md /app/skill.md
ENV SKILL_PATH=/app/skill.md
# The MCP client library logs the server's entire instruction block at INFO, which is
# half a screen of noise before the demo output. Warn keeps the projector clean.
ENTRYPOINT ["java","-Dorg.slf4j.simpleLogger.defaultLogLevel=warn","-jar","/app/app.jar"]
