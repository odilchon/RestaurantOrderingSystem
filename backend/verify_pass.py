from passlib.context import CryptContext

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
password = "password"
stored_hash = "$2b$12$KIXxPfnK6mFlW8F3iPvJIugc8aX9kYI7xTZ8w6vV4xZ0G5yH8Q9Wm"

result = pwd_context.verify(password, stored_hash)
print(f"Verify result: {result}")
