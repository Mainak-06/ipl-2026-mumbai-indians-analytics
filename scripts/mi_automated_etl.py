import pandas as pd
import glob
import os
import zipfile
import sqlalchemy
import urllib.parse

print("Step 1: Unzipping the data...")
zip_file = 'ipl_csv2 (1).zip'
extract_folder = 'ipl_unzipped'

# Unzip the downloaded file
with zipfile.ZipFile(zip_file, 'r') as zip_ref:
    zip_ref.extractall(extract_folder)

print("Step 2: Finding and stitching the correct match files...")
# Grab all CSVs, but IGNORE the info files AND the master 'all_matches' file!
all_csvs = glob.glob(os.path.join(extract_folder, '*.csv'))
valid_files = [
    f for f in all_csvs 
    if not f.endswith('_info.csv') 
    and 'all_matches' not in f.lower()
]

print(f"Found {len(valid_files)} pure match files. Combining now...")
df_list = []
for file in valid_files:
    try:
        df_list.append(pd.read_csv(file))
    except Exception as e:
        pass 

master_df = pd.concat(df_list, ignore_index=True)

print("\nStep 3: Filtering for the 2026 season...")
df_2026 = master_df[master_df['season'].astype(str).str.contains('2026', na=False)]
print(f"Total 2026 deliveries found: {len(df_2026)}")

print("\nStep 4: Pushing directly to MySQL...")
# Database Credentials
DB_USER = 'root'          
DB_PASSWORD = 'Mainak@2006' # Type your exact MySQL password here
DB_HOST = 'localhost'
DB_NAME = 'ipl_analytics'

try:
    # Safely encode the password for SQLAlchemy
    safe_password = urllib.parse.quote_plus(DB_PASSWORD)
    engine = sqlalchemy.create_engine(f'mysql+mysqlconnector://{DB_USER}:{safe_password}@{DB_HOST}/{DB_NAME}')
    
    # Push the data straight into the MySQL table
    df_2026.to_sql('deliveries', con=engine, if_exists='replace', index=False)
    print("\nSUCCESS! The full 2026 season is now live in your database!")
    
except Exception as e:
    print(f"Error connecting to MySQL: {e}")