CREATE ROLE hotel_app AUTHORIZATION dbo;
CREATE ROLE hotel_analyst AUTHORIZATION dbo;
GRANT EXECUTE ON SCHEMA::api TO hotel_app;
GRANT SELECT ON SCHEMA::report TO hotel_app;
GRANT SELECT ON SCHEMA::report TO hotel_analyst;
GRANT SELECT ON OBJECT::hotel.Hotel TO hotel_app;
GRANT SELECT ON OBJECT::hotel.RoomType TO hotel_app;
GRANT SELECT ON OBJECT::hotel.Room TO hotel_app;
GRANT SELECT ON OBJECT::hotel.Service TO hotel_app;
DENY INSERT, UPDATE, DELETE ON SCHEMA::hotel TO hotel_app;
DENY INSERT, UPDATE, DELETE ON SCHEMA::hotel TO hotel_analyst;
INSERT hotel.SchemaVersion(VersionNumber, Description) VALUES (1, N'Initial hotel booking schema, API and reporting');
GO
