FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY payment-service.csproj .
RUN dotnet restore
COPY *.cs ./
RUN dotnet publish -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:8.0
WORKDIR /app
COPY --from=build /app .
EXPOSE 8004
ENTRYPOINT ["dotnet", "payment-service.dll"]
