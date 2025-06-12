import os
import sys
import argparse
import datetime
import subprocess
from pathlib import Path

def run_command(command, cwd=None):
    print(command)
    try:
        result = subprocess.run(command, shell=True, cwd=cwd, check=True, 
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True)
        if result.stdout:
            print(result.stdout)
        return True
    except subprocess.CalledProcessError as e:
        print(f"Command failed with error: {e.stderr}")
        return False

def setup_repository(base_dir, remote_url, curr_date):
    # Create directory name based on date
    dir_name = f"script_{curr_date.strftime('%Y%m%d')}"
    print(f"curr_date {curr_date} directory {dir_name}")
    print(dir_name)
    
    # Create full path
    repo_path = os.path.join(base_dir, dir_name)
    os.makedirs(repo_path, exist_ok=True)
    
    # Initialize git operations
    commands = [
        ("merge abort", f"git merge --abort"),
        ("reset", f"git reset"),
        ("pulling...", f"git pull"),
        ("init", f"git init"),
        ("config", f"git config --global init.defaultBranch main"),
    ]
    
    for desc, cmd in commands:
        print(desc)
        run_command(cmd, repo_path)
    
    # Set start date
    start_date = curr_date - datetime.timedelta(hours=11, minutes=14)
    print(f"start date {start_date}")
    
    # Add remote
    print("adding remote")
    print(f"adding remote {remote_url}")
    run_command(f"git remote add origin {remote_url}", repo_path)
    
    # Pull, checkout, branch and push
    print("pulling")
    run_command(f"git pull origin main", repo_path)
    
    print("checking out")
    run_command(f"git checkout -b main", repo_path)
    
    print("branching")
    branch_name = f"feature/script_{curr_date.strftime('%Y%m%d')}"
    run_command(f"git checkout -b {branch_name}", repo_path)
    
    print("pushing")
    run_command(f"git push -u origin {branch_name}", repo_path)
    
    print("done\n")
    return True

def main():
    parser = argparse.ArgumentParser(description='Generate Julia set repository')
    parser.add_argument('-db', '--debug', type=int, default=0, help='Debug level')
    parser.add_argument('-r', '--remote', type=str, required=True, help='Remote repository URL')
    parser.add_argument('-mc', '--max_count', type=int, default=1, help='Maximum number of repositories to generate')
    
    args = parser.parse_args()
    
    base_dir = os.getcwd()
    curr_date = datetime.datetime(2024, 6, 1)
    
    success = setup_repository(base_dir, args.remote, curr_date)
    
    if success:
        print("\nRepository generation completed successfully!")
    else:
        print("\nRepository generation failed!")
        sys.exit(1)

if __name__ == "__main__":
    main() 