export function ProfileBio({ bio }: { bio: string }) {
  return <div className="bio" dangerouslySetInnerHTML={{ __html: bio }} />;
}
