# Built entirely in Docker: Maven and the JDK run in the first stage, so the machine
# running the lab needs Docker and nothing else. The runtime stage is a JRE and the jar.
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml .
RUN mvn -B -q dependency:go-offline || true
COPY src ./src
RUN mvn -B package -DskipTests

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /src/target/sre-java.jar /app/app.jar
# The MCP client logs the server's whole instruction block at INFO. Warn keeps the pod
# log to the lines this agent writes itself.
ENTRYPOINT ["java", "-Dorg.slf4j.simpleLogger.defaultLogLevel=warn", "-jar", "/app/app.jar"]
